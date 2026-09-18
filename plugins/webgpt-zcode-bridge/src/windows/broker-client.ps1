# webgpt-zcode-bridge - Windows broker client transport (Batch 5C).
# Drop-in replacement for cdp-client.ps1 at the transport seam consumed by
# webgpt-zcode-bridge.ps1: same five public functions, but every CLI invocation
# talks to the persistent per-user broker over an ACL'd named pipe instead of
# opening its own browser WebSocket (spec/cdp-broker-contract.md sections 2/6).
#
# Lifecycle:
#   - Initialize-WzbTransport  connects to (or starts) the broker and pings it.
#     Broker launch is on-demand: powershell.exe -NoProfile -ExecutionPolicy
#     Bypass -WindowStyle Hidden, detached from this CLI's lifetime. If a healthy
#     broker already answers ping it is REUSED - never a second instance.
#   - Get-WzbPages / Find-WzbPageUrl / Open-WzbPage / Invoke-WzbEval map 1:1 onto
#     broker ops list_pages / (client-side conv-id match, -ceq) / open_page /
#     evaluate, preserving exact-origin + exact-URL-filter semantics.
#   - Invoke-WzbCleanup is a no-op: the browser WebSocket belongs to the broker and
#     intentionally outlives this invocation.
#
# At-most-once at this seam: each request carries a fresh GUID op_id. If the pipe
# or the broker fails mid-request the CLI surfaces transport_failure - it never
# resends the same op_id (a retry would only ever receive the broker's cached
# terminal response anyway, but the CLI does not retry in-invocation, matching the
# historical one-invocation-one-connection discipline).
#
# Environment:
#   WZB_BROKER_CONNECT_TIMEOUT  per-attempt pipe connect seconds   (default 20)
#   WZB_BROKER_START_TIMEOUT    total wait after launching broker  (default 100;
#                               covers Chrome's Remote Debugging Allow dialog on
#                               the broker's FIRST browser connection)
#   WZB_TRANSPORT_MODE=direct   escape hatch: webgpt-zcode-bridge.ps1 loads
#                               cdp-client.ps1 instead (legacy per-invocation WS).

$ErrorActionPreference = 'Stop'

# Host-provided URL predicate + conversation-id parser (production definitions live in
# webgpt-zcode-bridge.ps1, which dot-sources this file). Fallbacks are identical logic,
# defined only when the host has not already supplied them (standalone tests).
if (-not (Get-Command Test-WzbWebgptUrl -ErrorAction SilentlyContinue)) {
  function Test-WzbWebgptUrl([string]$Url) {
    if (-not $Url) { return $false }
    try {
      $u = [Uri]$Url
      return ($u.Scheme -eq 'https' -and $u.Host -eq 'chatgpt.com' -and $u.IsDefaultPort)
    } catch { return $false }
  }
}
if (-not (Get-Command ConvertFrom-WzbConvId -ErrorAction SilentlyContinue)) {
  function ConvertFrom-WzbConvId([string]$Url) {
    if (-not (Test-WzbWebgptUrl $Url)) { return '' }
    $segs = ([Uri]$Url).AbsolutePath -split '/'
    for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
      if ($segs[$i] -ceq 'c' -and $segs[$i + 1] -ne '' -and $segs[$i + 1] -cmatch '^[A-Za-z0-9-]+$') { return $segs[$i + 1] }
    }
    return ''
  }
}

function Get-WzbEnvNum2([string]$Name, [double]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ($raw) { $v = 0.0; if ([double]::TryParse($raw, [ref]$v)) { return $v } }
  return $Default
}
$script:WzbPipeConnectS = Get-WzbEnvNum2 'WZB_BROKER_CONNECT_TIMEOUT' 20
$script:WzbBrokerStartS = Get-WzbEnvNum2 'WZB_BROKER_START_TIMEOUT' 100

function Get-WzbBrokerSidHash {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sid)) } finally { $sha.Dispose() }
  return (([BitConverter]::ToString($h) -replace '-', '').ToLower().Substring(0, 16))
}
$script:WzbPipeName = 'webgpt-zcode-bridge-' + (Get-WzbBrokerSidHash)

function Connect-WzbBrokerPipe([int]$TimeoutS) {
  $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:WzbPipeName, [System.IO.Pipes.PipeDirection]::InOut)
  try {
    $client.Connect([int]($TimeoutS * 1000))
    return $client
  } catch {
    try { $client.Dispose() } catch {}
    return $null
  }
}

function Read-WzbBrokerLine([System.IO.Pipes.NamedPipeClientStream]$Pipe) {
  $sr = New-Object System.IO.StreamReader($Pipe, [System.Text.Encoding]::UTF8)
  $line = $sr.ReadLine()
  if ($null -eq $line) { throw 'broker closed the pipe without a response' }
  return $line
}

function Write-WzbBrokerLine([System.IO.Pipes.NamedPipeClientStream]$Pipe, [string]$Json) {
  $sw = New-Object System.IO.StreamWriter($Pipe, [System.Text.Encoding]::UTF8)
  $sw.NewLine = "`n"
  $sw.WriteLine($Json)
  $sw.Flush()
}

# One request/response exchange over one pipe connection. Throws on any pipe/parse
# problem; NEVER retries the same op_id.
function Invoke-WzbBrokerExchange([hashtable]$Req) {
  $pipe = Connect-WzbBrokerPipe ([int]$script:WzbPipeConnectS)
  if ($null -eq $pipe) { throw 'broker pipe connect failed' }
  try {
    $Req['op_id'] = [Guid]::NewGuid().ToString('N')
    Write-WzbBrokerLine $pipe (ConvertTo-Json -InputObject $Req -Compress -Depth 24)
    $line = Read-WzbBrokerLine $pipe
    return ($line | ConvertFrom-Json)
  } finally {
    try { $pipe.Dispose() } catch {}
  }
}

# Ping the existing pipe WITHOUT starting anything (singleton reuse check).
function Test-WzbBrokerHealthy {
  $pipe = $null
  try {
    $pipe = Connect-WzbBrokerPipe 2
    if ($null -eq $pipe) { return $false }
    $req = @{ op = 'ping'; op_id = [Guid]::NewGuid().ToString('N') }
    Write-WzbBrokerLine $pipe (ConvertTo-Json -InputObject $req -Compress)
    $line = Read-WzbBrokerLine $pipe
    $r = $line | ConvertFrom-Json
    return ($r.ok -eq $true)
  } catch {
    return $false
  } finally {
    if ($null -ne $pipe) { try { $pipe.Dispose() } catch {} }
  }
}

function Start-WzbBrokerProcess {
  $broker = Join-Path $PSScriptRoot 'cdp-broker.ps1'
  # Detached, hidden, process-scoped execution policy only (contract section 6/7).
  $null = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $broker) `
    -WindowStyle Hidden -PassThru
}

# ---------- public transport interface (same envelope contract as cdp-client.ps1) ----------

$script:WzbBrokerInit = $null

function Initialize-WzbTransport {
  if ($null -ne $script:WzbBrokerInit -and $script:WzbBrokerInit.ok) { return $script:WzbBrokerInit }
  if (Test-WzbBrokerHealthy) {
    $script:WzbBrokerInit = @{ ok = $true; product = 'wzb-broker(reused)' }
    return $script:WzbBrokerInit
  }
  Start-WzbBrokerProcess
  $deadline = [DateTime]::UtcNow.AddSeconds($script:WzbBrokerStartS)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-WzbBrokerHealthy) {
      $script:WzbBrokerInit = @{ ok = $true; product = 'wzb-broker(started)' }
      return $script:WzbBrokerInit
    }
    Start-Sleep -Milliseconds 300
  }
  return @{ ok = $false; category = 'transport_failure'; reason = ('broker did not answer ping within ' + $script:WzbBrokerStartS + 's of launch (pipe=' + $script:WzbPipeName + ')') }
}

function Invoke-WzbClientOp([string]$Op, [hashtable]$Extra) {
  $req = @{ op = $Op }
  if ($Extra) { foreach ($k in $Extra.Keys) { $req[$k] = $Extra[$k] } }
  try {
    $r = Invoke-WzbBrokerExchange $req
    $out = @{}
    foreach ($p in $r.PSObject.Properties) { $out[$p.Name] = $p.Value }
    return $out
  } catch {
    # pipe/broker failure mid-exchange: terminal for this invocation; no op_id retry.
    $script:WzbBrokerInit = $null
    return @{ ok = $false; category = 'transport_failure'; reason = ('broker exchange failed (' + $Op + '): ' + $_.Exception.Message) }
  }
}

function Get-WzbPages {
  return (Invoke-WzbClientOp 'list_pages' $null)
}

function Find-WzbPageUrl([string]$ConvId) {
  $g = Get-WzbPages
  if (-not $g.ok) { return $g }
  foreach ($p in @($g.pages)) {
    $cid = ConvertFrom-WzbConvId ([string]$p.url)
    if ($cid -ceq $ConvId) { return @{ ok = $true; url = [string]$p.url } }
  }
  return @{ ok = $true; url = '' }
}

function Open-WzbPage([string]$Url) {
  return (Invoke-WzbClientOp 'open_page' @{ url = $Url })
}

function Invoke-WzbEval([string]$Filter, [string]$Js) {
  if (-not $Js) { return @{ ok = $false; category = 'transport_failure'; reason = 'eval: empty js' } }
  return (Invoke-WzbClientOp 'evaluate' @{ filter = ([string]$Filter); js = $Js })
}

function Invoke-WzbCleanup {
  # The browser WebSocket is owned by the persistent broker and intentionally
  # survives this CLI invocation (contract section 5.1). Nothing to clean here.
}
