# webgpt-zcode-bridge - Windows persistent CDP broker (Batch 5C).
# Long-lived per-user broker: many CLI invocations -> one named pipe -> this process ->
# ONE persistent browser ClientWebSocket -> Chrome (spec/cdp-broker-contract.md).
#
# Process model:
#   - launched on demand by broker-client.ps1 (Start-Process, detached, hidden window);
#   - singleton via a per-user named Mutex (Local\webgpt-zcode-bridge-broker-<sidhash>);
#     a second instance exits immediately (named pipes die with their owner process on
#     Windows, so there is no stale-socket cleanup problem);
#   - IPC: NamedPipeServerStream ONLY (no TCP listener), ACL restricted to the current
#     user via PipeSecurity/PipeAccessRule, one server instance => clients queue and
#     browser operations are serialized (contract section 8);
#   - protocol: one JSON request line in -> one JSON response line out, per connection
#     (contract section 7). ops: ping/status/list_pages/open_page/evaluate/shutdown.
#
# At-most-once (contract section 9, THE core rule):
#   - every request carries a unique op_id; the broker caches each op's terminal
#     response by op_id (bounded). A retried op_id returns the cached response/state
#     and is NEVER re-executed - not after a client pipe drop, not after a browser
#     WS failure, not after a reconnect.
#   - browser I/O is the existing, fault-suite-verified cdp-client.ps1 (dot-sourced,
#     or an injected fake via WZB_BROKER_BROWSER_DIR for synthetic tests). Its
#     per-invocation terminal semantics map onto per-operation semantics: once a
#     browser operation fails with an aborted/terminal socket, the browser layer is
#     RESET only BEFORE the next distinct operation (fresh WS; Chrome may re-prompt
#     Allow) - the failed operation itself is never replayed (contract sections 13/14).
#
# Privacy (contract section 14): no request payloads are persisted; diagnostics carry
# only op_id / CDP method names / error categories.
#
# Environment:
#   WZB_BROKER_BROWSER_DIR  when set, <dir>\browser.ps1 is dot-sourced instead of
#                           cdp-client.ps1 (synthetic broker tests inject a fake here);
#                           it must provide the same five public transport functions.
#   WZB_BROKER_IDLE_EXIT_S  optional; when > 0 the broker exits after N seconds with
#                           zero connected clients (0 = never; tests use small values).
#   WZB_CDP_*               passed through to cdp-client.ps1 as usual.

param()
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- per-user names (pipe + mutex embed a hash of the current user SID) ----------

function Get-WzbBrokerSidHash {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sid)) } finally { $sha.Dispose() }
  return (([BitConverter]::ToString($h) -replace '-', '').ToLower().Substring(0, 16))
}
$script:BrokerPipeName = 'webgpt-zcode-bridge-' + (Get-WzbBrokerSidHash)
$script:BrokerMutexName = 'Local\webgpt-zcode-bridge-broker-' + (Get-WzbBrokerSidHash)

function Write-WzbBrokerDiag([string]$Msg) {
  [Console]::Error.WriteLine('wzb-broker: ' + $Msg)
}

# ---------- browser layer (the fault-suite-verified transport, or a test fake) ----------

$script:BrokerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# The browser layer needs the host-provided URL predicate; the real one lives in the
# orchestrator. Define the production predicate here (identical logic to
# webgpt-zcode-bridge.ps1) before dot-sourcing so the shared definition binds once.
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
$browserDir = $env:WZB_BROKER_BROWSER_DIR
if ($browserDir) {
  . (Join-Path $browserDir 'browser.ps1')
} else {
  . (Join-Path $PSScriptRoot 'cdp-client.ps1')
}

# ---------- singleton (contract section 15) ----------

$createdNew = $false
$script:BrokerMutex = New-Object System.Threading.Mutex($true, $script:BrokerMutexName, [ref]$createdNew)
if (-not $createdNew) {
  # Another broker already owns the mutex. Named pipes disappear when their owning
  # process exits, so the existing broker either serves the pipe or is starting up.
  Write-WzbBrokerDiag 'another broker owns the singleton mutex; exiting'
  try { $script:BrokerMutex.ReleaseMutex() } catch {}
  $script:BrokerMutex.Dispose()
  exit 3
}

# ---------- op cache (at-most-once across pipe drops; bounded) ----------

$script:OpCache = @{}
$script:OpOrder = New-Object System.Collections.ArrayList
function Set-WzbOpCache([string]$OpId, [hashtable]$Response) {
  if (-not $script:OpCache.ContainsKey($OpId)) { [void]$script:OpOrder.Add($OpId) }
  $script:OpCache[$OpId] = $Response
  while ($script:OpOrder.Count -gt 128) {
    $old = [string]$script:OpOrder[0]
    $script:OpOrder.RemoveAt(0) | Out-Null
    $script:OpCache.Remove($old) | Out-Null
  }
}

# ---------- broker state ----------

$script:BrokerPid = $PID
$script:BrowserConnects = 0     # browser WS connections established by this broker
$script:OpsServed = 0
$script:ShuttingDown = $false

# Contract sections 13/14: reset the browser layer only BETWEEN operations, never to
# replay one. cdp-client's terminal flag is per-"invocation"; the broker maps one
# operation onto that lifecycle: after a terminal failure the whole browser state is
# dropped so the NEXT operation builds a fresh connection (Allow may reappear).
function Reset-WzbBrowserLayer {
  if ($script:WzbWsTerminal -or $script:WzbWsOpen -or $null -ne $script:WzbWs) {
    try { Invoke-WzbCleanup } catch {}
    $script:WzbWs = $null
    $script:WzbWsOpen = $false
    $script:WzbWsTerminal = $false
    $script:WzbSessions = @{}
    Write-WzbBrokerDiag 'browser layer reset (between operations; next op reconnects)'
  }
}

function Ensure-WzbBrowserLayer {
  if ($script:WzbWsTerminal) { Reset-WzbBrowserLayer }
  # already connected (and the real layer additionally re-verifies socket state inside
  # its own idempotent Initialize): skip straight to the operation
  if ($script:WzbWsOpen) { return @{ ok = $true } }
  $r = Initialize-WzbTransport
  if ($r.ok) { $script:BrowserConnects++ }
  return $r
}

# ---------- operation dispatch (one JSON request -> one JSON response) ----------

function Invoke-WzbBrokerOp([hashtable]$Req) {
  $op = [string]$Req.op
  $opId = [string]$Req.op_id
  if (-not $opId) { return @{ ok = $false; category = 'protocol_error'; reason = 'request missing op_id' } }
  if ($script:OpCache.ContainsKey($opId)) {
    # Contract section 9.2: an op_id that was already accepted/executed returns its
    # cached terminal response. Never re-execute, whatever happened to the client.
    $cached = $script:OpCache[$opId]
    $c = $cached.Clone()
    $c['cached'] = $true
    return $c
  }
  $resp = $null
  switch ($op) {
    'ping' {
      $resp = @{ ok = $true; op = 'ping'; broker_pid = $script:BrokerPid }
    }
    'status' {
      $resp = @{ ok = $true; op = 'status'; broker_pid = $script:BrokerPid
                 browser_ws_open = ($script:WzbWsOpen -and -not $script:WzbWsTerminal)
                 browser_connects = $script:BrowserConnects
                 ops_served = $script:OpsServed }
    }
    'shutdown' {
      $script:ShuttingDown = $true
      $resp = @{ ok = $true; op = 'shutdown'; broker_pid = $script:BrokerPid }
    }
    'list_pages' {
      $init = Ensure-WzbBrowserLayer
      if (-not $init.ok) { $resp = @{ ok = $false; category = [string]$init.category; reason = [string]$init.reason } ; break }
      $g = Get-WzbPages
      $resp = $g
    }
    'open_page' {
      $init = Ensure-WzbBrowserLayer
      if (-not $init.ok) { $resp = @{ ok = $false; category = [string]$init.category; reason = [string]$init.reason } ; break }
      $resp = Open-WzbPage ([string]$Req.url)
    }
    'evaluate' {
      $js = [string]$Req.js
      if (-not $js) { $resp = @{ ok = $false; category = 'protocol_error'; reason = 'evaluate: empty js' } ; break }
      $init = Ensure-WzbBrowserLayer
      if (-not $init.ok) { $resp = @{ ok = $false; category = [string]$init.category; reason = [string]$init.reason } ; break }
      # THE at-most-once call site: any failure terminal for this op_id; the browser
      # layer may be reset before the NEXT op, but this op is never re-sent.
      $resp = Invoke-WzbEval ([string]$Req.filter) $js
    }
    default {
      $resp = @{ ok = $false; category = 'protocol_error'; reason = ('unknown op: ' + $op) }
    }
  }
  if ($op -ne 'ping') { $script:OpsServed++ }
  if ($null -eq $resp) { $resp = @{ ok = $false; category = 'protocol_error'; reason = 'op produced no response' } }
  $resp['op_id'] = $opId
  Set-WzbOpCache $opId $resp
  return $resp
}

# ---------- named pipe server (ACL: current user only; 1 instance => serialized) ----------

function New-WzbBrokerPipe {
  $sec = New-Object System.IO.Pipes.PipeSecurity
  $rule = New-Object System.IO.Pipes.PipeAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
    [System.IO.Pipes.PipeAccessRights]::ReadWrite,
    [System.Security.AccessControl.AccessControlType]::Allow)
  $sec.AddAccessRule($rule)
  return (New-Object System.IO.Pipes.NamedPipeServerStream(
    $script:BrokerPipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    1,                                        # single instance: clients queue => serialized
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::None,
    0, 0, $sec))
}

$idleExitS = 0.0
if ($env:WZB_BROKER_IDLE_EXIT_S) { $v = 0.0; if ([double]::TryParse($env:WZB_BROKER_IDLE_EXIT_S, [ref]$v)) { $idleExitS = $v } }

Write-WzbBrokerDiag ('broker starting pid=' + $PID + ' pipe=' + $script:BrokerPipeName)

while (-not $script:ShuttingDown) {
  $pipe = $null
  try { $pipe = New-WzbBrokerPipe } catch {
    Write-WzbBrokerDiag ('pipe create failed: ' + $_.Exception.Message)
    break
  }
  try {
    $pipe.WaitForConnection()
  } catch {
    try { $pipe.Dispose() } catch {}
    continue
  }
  # one request per connection: read line -> dispatch -> write line -> disconnect
  try {
    $sr = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
    $line = $sr.ReadLine()
    if ($null -ne $line -and $line.Trim() -ne '') {
      $resp = $null
      try {
        $req = $line | ConvertFrom-Json
        $h = @{}
        foreach ($p in $req.PSObject.Properties) { $h[$p.Name] = $p.Value }
        $resp = Invoke-WzbBrokerOp $h
      } catch {
        $resp = @{ ok = $false; category = 'protocol_error'; reason = ('bad request: ' + $_.Exception.Message) }
      }
      $out = ConvertTo-Json -InputObject $resp -Compress -Depth 24
      $sw = New-Object System.IO.StreamWriter($pipe, [System.Text.Encoding]::UTF8)
      $sw.NewLine = "`n"
      $sw.WriteLine($out)
      $sw.Flush()
      # client may already be gone; a failed write just drops the (cached) response
      try { $sw.Dispose() } catch {}
    }
  } catch {
    # client disconnect mid-op is expected: the op itself already ran to completion
    # and its response is in the op cache; nothing to do (contract section 9.2)
  } finally {
    try { $pipe.Dispose() } catch {}
  }
}

try { Invoke-WzbCleanup } catch {}
Write-WzbBrokerDiag ('broker exiting pid=' + $PID)
try { $script:BrokerMutex.ReleaseMutex() } catch {}
$script:BrokerMutex.Dispose()
exit 0
