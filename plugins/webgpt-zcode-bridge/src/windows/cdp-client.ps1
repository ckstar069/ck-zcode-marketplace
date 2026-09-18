# webgpt-zcode-bridge - Windows CDP transport (PowerShell 5.1 + .NET ClientWebSocket).
# Loaded by src/windows/webgpt-zcode-bridge.ps1 (or a mock via WZB_TRANSPORT_DIR\transport.ps1).
#
# Boundary (ARCHITECTURE.md section 5 / Batch 4B):
#   Chrome process detection lives in the ORCHESTRATION layer (chrome_not_running);
#   this file only implements the CDP pipe after Chrome exists:
#     DevToolsActivePort read -> ONE persistent browser WebSocket per CLI invocation
#     -> Browser.getVersion -> Target.getTargets -> Target.createTarget (open only,
#        exact chatgpt.com origin only, background:true) -> Target.attachToTarget(flatten)
#     -> Runtime.evaluate (+ post-eval Target.getTargetInfo) -> clean dispose.
#   NO WebGPT business semantics here (endpoints, selectors, auth, conversation parsing) -
#   those live in src/common/page/* loaded byte-identical by the orchestrator.
#
# Host-provided dependency: the pure origin predicate Test-WzbWebgptUrl is defined by
# webgpt-zcode-bridge.ps1 BEFORE this file is dot-sourced (single production definition,
# reused here through PowerShell's dynamic scope; fault-injection tests inject their own).
#
# Lifecycle (Batch 4A frozen, hardened in 4B-FIX):
#   one CLI invocation = at most ONE browser WebSocket. "DevToolsActivePort exists" is
#   NOT health (4A proved stale residue on Windows too): init must really connect and
#   complete Browser.getVersion. After ANY ambiguous I/O failure (send/receive timeout,
#   socket close/drop) the socket is ABORTED and marked TERMINAL for the rest of this
#   invocation: no reconnect, no retry, no second Runtime.evaluate - the next CLI
#   invocation opens a fresh connection (also avoids a second Remote Debugging Allow).
#   A definitive CDP error response is NOT ambiguous I/O: the receive completed, the
#   socket stays healthy, only the targetId->sessionId cache is dropped so the NEXT
#   distinct operation may re-attach and send ONE new evaluation.
#
# At-most-once (Batch 4B blocking gate, unchanged): every Invoke-WzbEval sends
#   Runtime.evaluate AT MOST ONCE. Post-eval Target.getTargetInfo is a control/read
#   command, not a second page-JS evaluation, so it does not violate the gate; if it
#   fails after a successful evaluation the operation still returns transport_failure
#   and the evaluation is never replayed.
#
# Per-command monotonic deadline (4B-FIX Fix E): every Call-WzbCdp starts ONE
#   Stopwatch-based deadline; unrelated CDP events and message fragments consume the
#   SAME remaining budget - no per-event timeout reset; wall-clock changes cannot
#   stretch a command timeout.
#
# Transport interface (all functions return an envelope, never throw for business errors):
#   Initialize-WzbTransport            -> @{ok=$true} | @{ok=$false;category;reason}
#   Get-WzbPages                       -> @{ok=$true;pages=@(@{title;url},..)} | fail envelope
#   Find-WzbPageUrl -ConvId <id>       -> @{ok=$true;url='<url or empty>'} | fail envelope
#   Open-WzbPage -Url <u>              -> @{ok=$true} | fail envelope
#   Invoke-WzbEval -Filter <f> -Js <js>-> @{ok=$true;url;value}   (url = POST-eval URL) | fail envelope
#   Invoke-WzbCleanup                  -> [void] idempotent; closes only OUR socket.
# Cleanup never asks CDP to shut the browser or any target, and never touches Chrome.
#
# Test seam: New-WzbWebSocket is the only place a socket object is created; the
# fault-injection suite overrides this function with a fake wire (no real Chrome needed).
#
# Environment:
#   WZB_CDP_USER_DATA_DIR   Chrome user-data-dir (default %LOCALAPPDATA%\Google\Chrome\User Data)
#   WZB_CDP_CONNECT_TIMEOUT connect timeout seconds (default 90; Chrome pops an Allow
#                           dialog per new browser WebSocket - 4A user-verified - and the
#                           timeout must cover a human noticing and clicking it)
#   WZB_CDP_CMD_TIMEOUT     control CDP command timeout seconds (default 30)
#   WZB_CDP_EVAL_TIMEOUT    Runtime.evaluate timeout seconds (default 60; page JS does sync XHR)
#   WZB_CDP_DEBUG=1         stderr lifecycle debug (never page content / auth)

$script:WzbCdpConnectMs = ([double]$(if ($env:WZB_CDP_CONNECT_TIMEOUT) { $env:WZB_CDP_CONNECT_TIMEOUT } else { 90 })) * 1000
$script:WzbCdpCmdMs     = ([double]$(if ($env:WZB_CDP_CMD_TIMEOUT)     { $env:WZB_CDP_CMD_TIMEOUT }     else { 30 })) * 1000
$script:WzbCdpEvalMs    = ([double]$(if ($env:WZB_CDP_EVAL_TIMEOUT)    { $env:WZB_CDP_EVAL_TIMEOUT }    else { 60 })) * 1000
$script:WzbCdpDebug     = ($env:WZB_CDP_DEBUG -eq '1')
$script:WzbOrigin       = 'https://chatgpt.com'

# state for ONE CLI invocation
$script:WzbWs          = $null
$script:WzbWsOpen      = $false
$script:WzbWsTerminal  = $false   # set when the socket was aborted for ambiguous I/O; never cleared in-process
$script:WzbCdpSeq      = 0
$script:WzbSessions    = @{}      # targetId -> sessionId (same-invocation attach cache)
$script:WzbCleaned     = $false
$script:WzbRecvBuf     = New-Object byte[] 1048576

function Write-WzbCdpDebug([string]$Msg) {
  if ($script:WzbCdpDebug) { [Console]::Error.WriteLine('wzb-cdp: ' + $Msg) }
}

# Internal throw convention: Exception.Message = "category|reason". Only the five public
# functions translate it into envelopes; nothing outside catches page/business semantics.
function Throw-WzbCdp([string]$Category, [string]$Reason) {
  throw (New-Object System.Exception ($Category + '|' + $Reason))
}

# Ambiguous-I/O terminal path (Fix D): a real ClientWebSocket cannot have two concurrent
# ReceiveAsync calls, and a timed-out send/receive leaves the socket state unknowable.
# Abort + dispose our OWN socket, mark the transport terminal for this invocation, and
# fail. No reconnect, no retry - the next CLI invocation builds a fresh connection.
function Invoke-WzbAbortSocket([string]$Why) {
  if ($null -ne $script:WzbWs) {
    try { $script:WzbWs.Abort() } catch {}
    try { $script:WzbWs.Dispose() } catch {}
    $script:WzbWs = $null
  }
  $script:WzbWsOpen = $false
  $script:WzbWsTerminal = $true
  Write-WzbCdpDebug ('socket aborted (terminal): ' + $Why)
}

# Safe descriptor for I/O failures: exception TYPE NAMES only. Real socket exceptions
# carry system-level messages, but we never risk echoing anything payload-derived.
function Get-WzbSafeExType([System.Exception]$Exc) {
  if ($null -eq $Exc) { return 'Exception' }
  $t = $Exc.GetType().Name
  if ($Exc.InnerException) { $t += '(' + $Exc.InnerException.GetType().Name + ')' }
  return $t
}

# ---------- DevToolsActivePort ----------
function Read-WzbEndpoint {
  $udd = $env:WZB_CDP_USER_DATA_DIR
  if (-not $udd) { $udd = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
  $dtap = Join-Path $udd 'DevToolsActivePort'
  if (-not (Test-Path -LiteralPath $dtap)) {
    Throw-WzbCdp 'remote_debugging_unavailable' ("DevToolsActivePort not found under " + $udd + "; enable Remote Debugging at chrome://inspect/#remote-debugging")
  }
  $lines = @(Get-Content -LiteralPath $dtap)
  $port = [string]$lines[0]
  $path = if ($lines.Count -ge 2) { [string]$lines[1] } else { '' }
  if ($port -notmatch '^[0-9]{1,5}$' -or ([int]$port -lt 1 -or [int]$port -gt 65535) -or -not $path.StartsWith('/')) {
    Throw-WzbCdp 'remote_debugging_unavailable' ("DevToolsActivePort malformed (port='" + $port + "', path=" + $(if ($path) { 'present' } else { 'missing' }) + ")")
  }
  return @{ url = ('ws://127.0.0.1:' + $port + $path); port = $port }
}

# ---------- socket seam (overridden by the fault-injection fake wire) ----------
function New-WzbWebSocket {
  return (New-Object System.Net.WebSockets.ClientWebSocket)
}

# ---------- frame I/O ----------
# Fix 1 + Fix 3 (4B-FIX2): the send phase consumes the SAME per-command monotonic budget
# as the receive phase (BudgetMs = remaining budget handed in by Call-WzbCdp), and EVERY
# ambiguous send failure - synchronous throw, Wait(timeout)==false, Faulted or Canceled
# task - aborts the socket and marks the transport terminal for this invocation.
function Send-WzbCdpFrame([object]$Obj, [int]$BudgetMs) {
  if ($BudgetMs -le 0) {
    Invoke-WzbAbortSocket 'send budget exhausted'
    Throw-WzbCdp 'transport_failure' 'CDP send deadline exceeded (budget exhausted)'
  }
  $json = ConvertTo-Json -InputObject $Obj -Compress -Depth 8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $seg = [System.ArraySegment[byte]]::new($bytes)
  $task = $null
  try {
    $task = $script:WzbWs.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
  } catch {
    Invoke-WzbAbortSocket ('send threw synchronously: ' + (Get-WzbSafeExType $_.Exception))
    Throw-WzbCdp 'transport_failure' ('CDP send failed: ' + (Get-WzbSafeExType $_.Exception))
  }
  try {
    if (-not $task.Wait([int]$BudgetMs)) {
      Invoke-WzbAbortSocket 'send timeout'
      Throw-WzbCdp 'transport_failure' 'CDP send timeout'
    }
  } catch {
    Invoke-WzbAbortSocket ('send task faulted/canceled: ' + (Get-WzbSafeExType $_.Exception))
    Throw-WzbCdp 'transport_failure' ('CDP send failed: ' + (Get-WzbSafeExType $_.Exception))
  }
}

# One budget for the whole (possibly fragmented) message; caller passes the command's
# REMAINING budget so events/fragments can never extend the command deadline.
function Receive-WzbCdpFrame([int]$BudgetMs) {
  if ($BudgetMs -le 0) {
    Invoke-WzbAbortSocket 'receive budget exhausted'
    Throw-WzbCdp 'transport_failure' 'CDP response timeout (budget exhausted)'
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $ms = New-Object System.IO.MemoryStream
  while ($true) {
    $remain = [int]($BudgetMs - $sw.ElapsedMilliseconds)
    if ($remain -le 0) {
      Invoke-WzbAbortSocket 'receive timeout'
      Throw-WzbCdp 'transport_failure' ('CDP response timeout after ' + [int]($BudgetMs / 1000) + 's')
    }
    $seg = [System.ArraySegment[byte]]::new($script:WzbRecvBuf)
    $task = $null
    try {
      $task = $script:WzbWs.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
    } catch {
      Invoke-WzbAbortSocket ('receive threw synchronously: ' + (Get-WzbSafeExType $_.Exception))
      Throw-WzbCdp 'transport_failure' ('CDP receive failed: ' + (Get-WzbSafeExType $_.Exception))
    }
    try {
      $done = $task.Wait($remain)
    } catch {
      Invoke-WzbAbortSocket ('receive task faulted/canceled: ' + (Get-WzbSafeExType $_.Exception))
      Throw-WzbCdp 'transport_failure' ('CDP receive failed: ' + (Get-WzbSafeExType $_.Exception))
    }
    if (-not $done) {
      Invoke-WzbAbortSocket 'receive timeout'
      Throw-WzbCdp 'transport_failure' ('CDP response timeout after ' + [int]($BudgetMs / 1000) + 's')
    }
    try {
      $r = $task.Result
    } catch {
      Invoke-WzbAbortSocket ('receive result faulted: ' + (Get-WzbSafeExType $_.Exception))
      Throw-WzbCdp 'transport_failure' ('CDP receive failed: ' + (Get-WzbSafeExType $_.Exception))
    }
    if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
      # peer closed mid-command: response delivery is ambiguous -> terminal
      Invoke-WzbAbortSocket 'websocket closed by peer'
      Throw-WzbCdp 'transport_failure' 'browser WebSocket closed by peer mid-invocation'
    }
    $ms.Write($script:WzbRecvBuf, 0, $r.Count)
    if ($r.EndOfMessage) {
      $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
      return ($text | ConvertFrom-Json)
    }
  }
}

# ---------- per-command monotonic deadline (Fix E) ----------
function Call-WzbCdp([string]$Method, $Params, [string]$SessionId, [int]$TimeoutMs) {
  if ($script:WzbWsTerminal) {
    Throw-WzbCdp 'transport_failure' 'transport is terminal for this invocation (socket aborted); no reconnect, no retry'
  }
  if (-not $script:WzbWsOpen) { Throw-WzbCdp 'transport_failure' 'browser WebSocket is not open' }
  $script:WzbCdpSeq++
  $id = $script:WzbCdpSeq
  $msg = @{ id = $id; method = $Method; params = $Params }
  if ($SessionId) { $msg.sessionId = $SessionId }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $sendRemaining = [int]($TimeoutMs - $sw.ElapsedMilliseconds)
  if ($sendRemaining -le 0) {
    Invoke-WzbAbortSocket 'command deadline exceeded before send'
    Throw-WzbCdp 'transport_failure' ('CDP ' + $Method + ' deadline exceeded after ' + [int]($TimeoutMs / 1000) + 's')
  }
  Send-WzbCdpFrame $msg $sendRemaining       # sent exactly once, SAME command budget
  while ($true) {
    $remaining = [int]($TimeoutMs - $sw.ElapsedMilliseconds)
    if ($remaining -le 0) {
      Invoke-WzbAbortSocket 'command deadline exceeded'
      Throw-WzbCdp 'transport_failure' ('CDP ' + $Method + ' deadline exceeded after ' + [int]($TimeoutMs / 1000) + 's')
    }
    $m = Receive-WzbCdpFrame $remaining      # events + fragments share the SAME deadline
    if ($null -ne $m.id -and [int]$m.id -eq $id) {
      if ($m.error) {
        # definitive CDP error response: receive completed, socket stays healthy
        Throw-WzbCdp 'transport_failure' ('CDP ' + $Method + ': ' + $m.error.message)
      }
      return $m.result
    }
    # unrelated CDP event (no id): ignored, SAME deadline continues
  }
}

# ---------- target / session ----------
function Get-WzbChatgptTargetsRaw {
  $r = Call-WzbCdp 'Target.getTargets' @{} $null ([int]$script:WzbCdpCmdMs)
  # exact-origin filter (Fix A): only https://chatgpt.com default-port pages are WebGPT
  return @($r.targetInfos | Where-Object { $_.type -eq 'page' -and (Test-WzbWebgptUrl ([string]$_.url)) })
}

function Attach-WzbTarget([string]$TargetId) {
  $a = Call-WzbCdp 'Target.attachToTarget' @{ targetId = $TargetId; flatten = $true } $null ([int]$script:WzbCdpCmdMs)
  $script:WzbSessions[$TargetId] = [string]$a.sessionId
  Write-WzbCdpDebug ('attached target (cached sessions: ' + $script:WzbSessions.Count + ')')
  return [string]$a.sessionId
}

# Read-only control command (NOT a page-JS evaluation): resolves the target's CURRENT
# url after an evaluation completed, closing the pre-eval-URL TOCTOU window (Fix C).
function Get-WzbPostEvalUrl([string]$TargetId) {
  $g = Call-WzbCdp 'Target.getTargetInfo' @{ targetId = $TargetId } $null ([int]$script:WzbCdpCmdMs)
  if ($g.targetInfo -and $g.targetInfo.url) { return [string]$g.targetInfo.url }
  Throw-WzbCdp 'transport_failure' ('post-eval Target.getTargetInfo returned no url for target ' + $TargetId)
}

# ---------- public transport interface ----------

function Initialize-WzbTransport {
  if ($script:WzbWsTerminal) {
    return @{ ok = $false; category = 'transport_failure'; reason = 'transport is terminal for this invocation (socket aborted); no reconnect within one CLI invocation' }
  }
  if ($script:WzbWsOpen -and $script:WzbWs -and $script:WzbWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
    return @{ ok = $true }   # idempotent: same CLI invocation reuses the one connection
  }
  try {
    $ep = Read-WzbEndpoint
    $t0 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $ws = New-WzbWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource([int]$script:WzbCdpConnectMs)
    try { $ws.ConnectAsync([Uri]$ep.url, $cts.Token).Wait() | Out-Null }
    catch { Throw-WzbCdp 'remote_debugging_unavailable' ('cannot connect to loopback endpoint 127.0.0.1:' + $ep.port + ' (refused/unusable - stale DevToolsActivePort or Remote Debugging disabled; if Chrome shows an Allow dialog, approve Remote Debugging)') }
    $script:WzbWs = $ws
    $script:WzbWsOpen = $true
    $v = Call-WzbCdp 'Browser.getVersion' @{} $null ([int]$script:WzbCdpCmdMs)
    Write-WzbCdpDebug ('connected in ' + [int](1000 * ([System.Diagnostics.Stopwatch]::GetTimestamp() - $t0) / [System.Diagnostics.Stopwatch]::Frequency) + 'ms; ' + $v.product)
    return @{ ok = $true; product = [string]$v.product }
  } catch {
    $script:WzbWsOpen = $false
    if ($null -ne $script:WzbWs) { try { $script:WzbWs.Dispose() } catch {} ; $script:WzbWs = $null }
    $msg = $_.Exception.Message
    $cat, $rest = $msg -split '\|', 2
    if (-not $rest) { $cat = 'transport_failure'; $rest = $msg }
    return @{ ok = $false; category = $cat; reason = $rest }
  }
}

function Get-WzbPages {
  try {
    $targets = Get-WzbChatgptTargetsRaw
    $pages = @()
    foreach ($t in $targets) { $pages += @{ title = [string]$t.title; url = [string]$t.url } }
    return @{ ok = $true; pages = $pages }
  } catch {
    $cat, $rest = ([string]$_.Exception.Message) -split '\|', 2
    if (-not $rest) { $cat = 'transport_failure'; $rest = [string]$_.Exception.Message }
    return @{ ok = $false; category = $cat; reason = $rest }
  }
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
  if (-not (Test-WzbWebgptUrl $Url)) {
    return @{ ok = $false; category = 'transport_failure'; reason = ('open_page refused non-chatgpt.com-origin URL: ' + $Url) }
  }
  try {
    $null = Call-WzbCdp 'Target.createTarget' @{ url = $Url; background = $true } $null ([int]$script:WzbCdpCmdMs)
    return @{ ok = $true }
  } catch {
    $cat, $rest = ([string]$_.Exception.Message) -split '\|', 2
    if (-not $rest) { $cat = 'transport_failure'; $rest = [string]$_.Exception.Message }
    return @{ ok = $false; category = $cat; reason = $rest }
  }
}

# THE at-most-once Runtime.evaluate call site. One operation sends the request exactly
# once; any failure fails the operation (never a resend of the same JS). On failure the
# session cache entry for this target is dropped so the NEXT distinct operation can
# recover via fresh getTargets+attach. Page-level exceptionDetails is a definitive
# response (delivery known), mapped to transport_failure without aborting the socket.
# After a successful evaluation the returned url is the POST-eval URL resolved via
# Target.getTargetInfo (Fix C) - if that lookup fails the operation fails as
# transport_failure and the evaluation is still never replayed.
function Invoke-WzbEval([string]$Filter, [string]$Js) {
  if (-not $Js) { return @{ ok = $false; category = 'transport_failure'; reason = 'eval: empty js' } }
  # Fix B (4B-FIX3): non-empty Filter binds by EXACT ordinal URL equality - a page whose
  # URL merely CONTAINS the filter (e.g. https://chatgpt.com/?next=<filter>) must NOT be
  # selected: no match, no Runtime.evaluate. Empty Filter = stable first page (read cmds).
  $f = [string]$Filter
  try {
    $targets = Get-WzbChatgptTargetsRaw
    $target = $null
    foreach ($t in $targets) {
      if ($f -eq '' -or [string]::Equals([string]$t.url, $f, [System.StringComparison]::Ordinal)) { $target = $t; break }
    }
    if ($null -eq $target) {
      # enumeration may be stale (tab closed/navigated): re-enumerate ONCE, then give up.
      $targets = Get-WzbChatgptTargetsRaw
      foreach ($t in $targets) {
        if ($f -eq '' -or [string]::Equals([string]$t.url, $f, [System.StringComparison]::Ordinal)) { $target = $t; break }
      }
    }
    if ($null -eq $target) {
      return @{ ok = $false; category = 'no_webgpt_page'; reason = ('no open ' + $script:WzbOrigin + ' page matches filter ''' + $f + '''') }
    }
    $tid = [string]$target.targetId
    $sid = $script:WzbSessions[$tid]
    if (-not $sid) { $sid = Attach-WzbTarget $tid }
    try {
      $r = Call-WzbCdp 'Runtime.evaluate' @{ expression = $Js; awaitPromise = $true; returnByValue = $true } $sid ([int]$script:WzbCdpEvalMs)
    } catch {
      # delivery state undecidable - NEVER replay. Drop cache; next operation re-attaches.
      $script:WzbSessions.Remove($tid) | Out-Null
      throw
    }
    if ($r.exceptionDetails) {
      $d = $r.exceptionDetails
      $desc = ''
      if ($d.exception -and $d.exception.description) { $desc = [string]$d.exception.description }
      elseif ($d.exception -and $null -ne $d.exception.value) { $desc = [string]$d.exception.value }
      elseif ($d.text) { $desc = [string]$d.text }
      if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) }
      return @{ ok = $false; category = 'transport_failure'; reason = ('page evaluation exception: ' + $desc) }
    }
    try {
      $postUrl = Get-WzbPostEvalUrl $tid
    } catch {
      # evaluation itself completed, but the post-eval URL lookup failed: fail the whole
      # operation; the evaluation is NOT replayed. Session state is now untrusted.
      $script:WzbSessions.Remove($tid) | Out-Null
      $msg = [string]$_.Exception.Message
      $cat, $rest = $msg -split '\|', 2
      if (-not $rest) { $cat = 'transport_failure'; $rest = $msg }
      return @{ ok = $false; category = $cat; reason = ('post-eval target URL resolution failed; evaluation result discarded; ' + $rest) }
    }
    $v = $null
    if ($r.result -and $null -ne $r.result.value) { $v = $r.result.value }
    $value = if ($null -eq $v) { '' } elseif ($v -is [string]) { $v } else { ConvertTo-Json -InputObject $v -Compress -Depth 32 }
    return @{ ok = $true; url = $postUrl; value = $value }
  } catch {
    $cat, $rest = ([string]$_.Exception.Message) -split '\|', 2
    if (-not $rest) { $cat = 'transport_failure'; $rest = [string]$_.Exception.Message }
    return @{ ok = $false; category = $cat; reason = $rest }
  }
}

function Invoke-WzbCleanup {
  if ($script:WzbCleaned) { return }
  $script:WzbCleaned = $true
  if ($null -ne $script:WzbWs) {
    try {
      if ($script:WzbWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $cts = New-Object System.Threading.CancellationTokenSource(3000)
        $script:WzbWs.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'bye', $cts.Token).Wait(3000) | Out-Null
      }
    } catch { try { $script:WzbWs.Abort() } catch {} }
    try { $script:WzbWs.Dispose() } catch {}
    $script:WzbWs = $null
  }
  $script:WzbWsOpen = $false
  Write-WzbCdpDebug 'socket disposed'
}
