# webgpt-zcode-bridge - Windows entry + orchestration (native PowerShell 5.1, Candidate B).
# Semantics are frozen by spec/cli-contract.md + spec/page-contract.md; the Bash common
# layer (src/common/cli.sh) is the behavioral reference - this file ports its orchestration
# 1:1 (Batch 4B), NOT its business logic: every WebGPT page/DOM/backend semantic stays in
# src/common/page/*.js, loaded byte-identical from WZB_PAGE_DIR and executed inside the
# real chatgpt.com page via the CDP transport (cdp-client.ps1 or a mock transport.ps1 via
# WZB_TRANSPORT_DIR - the same injection convention as the Bash entries).
#
# Usage:
#   webgpt-zcode-bridge.ps1 list [limit]
#   webgpt-zcode-bridge.ps1 find <keyword>
#   webgpt-zcode-bridge.ps1 conv <conversation-id>
#   webgpt-zcode-bridge.ps1 transcript <conversation-id>
#   webgpt-zcode-bridge.ps1 send [--conv <conversation-id>] [--send] [--verify] "<message>"
# Exit: 0 success / 1 runtime-browser-transport-page-backend-verify error / 2 usage error.
# stdout carries exactly ONE JSON document (conv success outputs the raw backend document);
# diagnostics go to stderr. No incidental pipeline output reaches stdout.
#
# Safety state machine (page-contract section 21 / section 16.2) - ported from cli.sh:
#   ComposerOwned      set only after SendPrecheck write + exact canonical readback;
#                      before it, no automatic cleanup ever runs.
#   ClearPhaseStarted  set immediately before the first ClearIfExact of a dry-run;
#                      from then on generic rollback is disabled (clear mutation at most once).
#   ClickAttempted     set immediately BEFORE the SendClick evaluation; from then on
#                      automatic composer cleanup is permanently disabled - if transport
#                      then fails we cannot assert whether the click happened.
#
# Test seam: WZB_SOURCE_ONLY=1 loads this file without running main (unit tests of the
# pure helpers). No retry/behavior switch is hidden behind any environment variable.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}

$script:WzbSelf    = $PSScriptRoot
$script:WzbRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:WzbPageDir = if ($env:WZB_PAGE_DIR) { $env:WZB_PAGE_DIR } else { Join-Path $script:WzbRoot 'src\common\page' }

function Get-WzbEnvNum([string]$Name, [double]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ($raw) { $v = 0.0; if ([double]::TryParse($raw, [ref]$v)) { return $v } }
  return $Default
}
$script:ReadyTimeoutS  = Get-WzbEnvNum 'WZB_READY_TIMEOUT'  30
$script:ReadyIntervalS = Get-WzbEnvNum 'WZB_READY_INTERVAL' 0.5
$script:BtnTimeoutS    = Get-WzbEnvNum 'WZB_BTN_TIMEOUT'    3
$script:BtnIntervalS   = Get-WzbEnvNum 'WZB_BTN_INTERVAL'   0.1
$script:ClearTimeoutS  = Get-WzbEnvNum 'WZB_CLEAR_TIMEOUT'  2
$script:ClearIntervalS = Get-WzbEnvNum 'WZB_CLEAR_INTERVAL' 0.1
$script:VerifyTimeoutS = Get-WzbEnvNum 'WZB_VERIFY_TIMEOUT' 15
$script:VerifyIntervalS = Get-WzbEnvNum 'WZB_VERIFY_INTERVAL' 1

function Get-WzbNow { [System.Diagnostics.Stopwatch]::GetTimestamp() }
function Get-WzbMs([long]$T0) { [int](1000 * ([System.Diagnostics.Stopwatch]::GetTimestamp() - $T0) / [System.Diagnostics.Stopwatch]::Frequency) }

# ---------- output / failure ----------

function Write-WzbJsonLine([string]$Json) { [Console]::Out.WriteLine($Json) }
function Write-WzbErr([string]$Text)      { [Console]::Error.WriteLine($Text) }

function ConvertTo-WzbErrorJson([string]$Category, [string]$Reason, [hashtable]$Extra) {
  $o = [ordered]@{ ok = $false; category = $Category; reason = $Reason }
  if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
  return (ConvertTo-Json -InputObject $o -Compress)
}

function Wzb-Fail([string]$Category, [string]$Reason, [int]$ExitCode = 1, [hashtable]$Extra = $null) {
  Write-WzbJsonLine (ConvertTo-WzbErrorJson $Category $Reason $Extra)
  exit $ExitCode
}

function Wzb-UsageFail([string]$Message) {
  Write-WzbErr ('usage error: ' + $Message)
  Wzb-Fail 'usage_error' $Message 2
}

# Bare JSON array output that never collapses to a scalar for 0/1 elements.
function ConvertTo-WzbJsonArray([object[]]$Items) {
  $arr = @($Items)
  if ($arr.Count -eq 0) { return '[]' }
  $parts = @()
  foreach ($i in $arr) { $parts += (ConvertTo-Json -InputObject $i -Compress -Depth 16) }
  return ('[' + ($parts -join ',') + ']')
}

# ---------- pre-click cleanup state (set in Wzb-InvokeSend) ----------
$script:ComposerOwned    = 0
$script:ClearPhaseStarted= 0
$script:ClickAttempted   = 0
$script:MsgJson          = ''
$script:TargetUrl        = ''

function Wzb-FailGuarded([string]$Category, [string]$Reason, [int]$ExitCode = 1, [hashtable]$Extra = $null) {
  if ($script:ComposerOwned -eq 1 -and $script:ClickAttempted -eq 0 -and $script:ClearPhaseStarted -eq 0) {
    Wzb-PreclickRollback $Category $Reason
  }
  Wzb-Fail $Category $Reason $ExitCode $Extra
}

# ---------- WebGPT origin predicate + URL -> conversation id ----------
# Fix A (4B-FIX): a WebGPT page is EXACTLY scheme=https, host=chatgpt.com, HTTPS default
# port. StartsWith("https://chatgpt.com") is NOT used for any security decision: it
# accepts lookalike hosts (chatgpt.com.evil.example), wrong schemes, odd ports and
# foreign URLs merely containing the string. Defined here (before the transport
# dot-source) so the real CDP transport, the mock transport and this file share ONE
# production definition through PowerShell's dynamic scope.
function Test-WzbWebgptUrl([string]$Url) {
  if (-not $Url) { return $false }
  try {
    $u = [Uri]$Url
    return ($u.Scheme -eq 'https' -and $u.Host -eq 'chatgpt.com' -and $u.IsDefaultPort)
  } catch { return $false }
}

# Fix B (4B-FIX): parse the URL, then resolve /c/<id> ONLY from Uri.AbsolutePath segments.
# Query strings and fragments that merely CONTAIN "/c/..." are never treated as
# conversation references, and non-chatgpt.com origins never yield an id.
function ConvertFrom-WzbConvId([string]$Url) {
  if (-not (Test-WzbWebgptUrl $Url)) { return '' }
  $segs = ([Uri]$Url).AbsolutePath -split '/'
  for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
    if ($segs[$i] -ceq 'c' -and $segs[$i + 1] -ne '' -and $segs[$i + 1] -cmatch '^[A-Za-z0-9-]+$') {
      return $segs[$i + 1]
    }
  }
  return ''
}

# ---------- page bundle composition (same file map as cli.sh wzb_page_files) ----------

function Get-WzbPageFiles([string]$Entry) {
  switch ($Entry) {
    'webgptPageList'            { return @('auth.js','conversations.js') }
    'webgptPageFindList'        { return @('auth.js','conversations.js') }
    'webgptPageConvRaw'         { return @('auth.js','transcript.js','conversation.js') }
    'webgptPageTranscript'      { return @('auth.js','transcript.js','conversation.js') }
    'webgptPageVerifySnapshot'  { return @('auth.js','transcript.js','verify.js','conversation.js') }
    'webgptPageVerifyCheck'     { return @('auth.js','transcript.js','verify.js','conversation.js') }
    'webgptPageReadiness'       { return @('auth.js','identity.js','composer.js') }
    'webgptPageSendPrecheck'    { return @('auth.js','transcript.js','identity.js','composer.js') }
    'webgptPageSendReady'       { return @('auth.js','composer.js') }
    'webgptPageComposerState'   { return @('auth.js','composer.js') }
    'webgptPageComposerClearIfExact' { return @('auth.js','transcript.js','identity.js','composer.js') }
    'webgptPageSendClick'       { return @('auth.js','transcript.js','identity.js','composer.js') }
    default { return $null }
  }
}

# ---------- page evaluation ----------

# Builds the page bundle exactly like cli.sh: shared file contents + wrapper that stringifies
# the entry result or converts any page exception into a page_runtime_error envelope.
function Build-WzbPageJs([string]$Entry, [string[]]$ArgJsons) {
  $js = ''
  foreach ($f in (Get-WzbPageFiles $Entry)) {
    $js += [System.IO.File]::ReadAllText((Join-Path $script:WzbPageDir $f))
    $js += "`n"
  }
  $args_ = ($ArgJsons -join ',')
  return ($js + '(function(){try{return JSON.stringify(' + $Entry + '.apply(null,[' + $args_ + ']))}catch(e){return JSON.stringify({ok:false,category:' + "'page_runtime_error'" + ',reason:String(e)})}})()')
}

# Result slots: WzbTabUrl / WzbPageResult (raw string) / WzbPageObj (parsed) / WzbEvalFail.
function Wzb-EvalPageSoft([string]$Filter, [string]$Entry, [string[]]$ArgJsons) {
  if ($null -eq (Get-WzbPageFiles $Entry)) {
    $script:WzbEvalFail = 'transport_failure|unknown page entry: ' + $Entry
    return $false
  }
  $js = Build-WzbPageJs $Entry $ArgJsons
  $r = Invoke-WzbEval -Filter $Filter -Js $js
  if (-not $r.ok) {
    $script:WzbEvalFail = ([string]$r.category + '|' + [string]$r.reason)
    return $false
  }
  $script:WzbTabUrl     = [string]$r.url
  $script:WzbPageResult = [string]$r.value
  try { $script:WzbPageObj = $script:WzbPageResult | ConvertFrom-Json }
  catch {
    $script:WzbEvalFail = 'page_runtime_error|page returned non-JSON payload'
    return $false
  }
  return $true
}

function Wzb-EvalPage([string]$Filter, [string]$Entry, [string[]]$ArgJsons) {
  if (-not (Wzb-EvalPageSoft $Filter $Entry $ArgJsons)) {
    $f = $script:WzbEvalFail
    Wzb-FailGuarded ($f -split '\|', 2)[0] ($(if (($f -split '\|', 2).Count -ge 2) { ($f -split '\|', 2)[1] } else { $f }))
  }
}

function Wzb-RequirePageOk {
  if ($script:WzbPageObj.ok -ne $true) {
    $cat = 'page_runtime_error'; $rsn = 'page evaluation failed'
    if ($script:WzbPageObj.category) { $cat = [string]$script:WzbPageObj.category }
    if ($script:WzbPageObj.reason)   { $rsn = [string]$script:WzbPageObj.reason }
    Wzb-FailGuarded $cat $rsn 1
  }
}

# After every evaluation in the send flow the executing page must still resolve to the
# target conversation id (page-contract section 14: any change fails immediately).
function Wzb-AssertTargetUnchanged {
  $cid = ConvertFrom-WzbConvId $script:WzbTabUrl
  if ($cid -cne $script:TargetId) {
    Wzb-FailGuarded 'target_changed' ("executing page resolved to conversation '" + $(if ($cid) { $cid } else { 'none' }) + "', expected '" + $script:TargetId + "'")
  }
}

# ---------- transport init ----------

function Test-WzbChromeRunning {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue)
  foreach ($p in $procs) {
    if ($p.ExecutablePath -and $p.ExecutablePath -like '*\Google\Chrome\Application\chrome.exe') {
      if (-not $p.CommandLine -or $p.CommandLine -notmatch '--type=') { return $true }
    }
  }
  return $false
}

function Wzb-RunTransportInit {
  if (-not (Test-WzbChromeRunning)) {
    Wzb-Fail 'chrome_not_running' 'Google Chrome is not running; open Chrome with a logged-in chatgpt.com tab'
  }
  $r = Initialize-WzbTransport
  if (-not $r.ok) { Wzb-Fail ([string]$r.category) ([string]$r.reason) }
}

# ---------- transport call helpers (transport envelope -> failure) ----------

function Wzb-GetPagesOrFail {
  $g = Get-WzbPages
  if (-not $g.ok) { Wzb-Fail ([string]$g.category) ([string]$g.reason) }
  return @($g.pages)
}

function Wzb-FindPageUrlOrFail([string]$ConvId) {
  $r = Find-WzbPageUrl -ConvId $ConvId
  if (-not $r.ok) { Wzb-Fail ([string]$r.category) ([string]$r.reason) }
  return [string]$r.url
}

function Wzb-OpenPageOrFail([string]$Url) {
  $r = Open-WzbPage -Url $Url
  if (-not $r.ok) { Wzb-Fail ([string]$r.category) ([string]$r.reason) }
}

# ---------- polling (page-contract section 16.2: read-only bounded poll, no repeat mutation) ----------
# Returns 0 = confirmed empty, 1 = timeout, 2 = evaluation error.

function Wzb-PollComposerEmpty([string]$Filter) {
  $deadline = (Get-WzbNow) + [int64]($script:ClearTimeoutS * [System.Diagnostics.Stopwatch]::Frequency)
  while ($true) {
    if (-not (Wzb-EvalPageSoft $Filter 'webgptPageComposerState' @())) { return 2 }
    $exists = $false
    if ($script:WzbPageObj.exists -eq $true) { $exists = $true }
    if ($exists -and [string]$script:WzbPageObj.text -eq '') { return 0 }
    if ((Get-WzbNow) -ge $deadline) { return 1 }
    Start-Sleep -Milliseconds ([int]($script:ClearIntervalS * 1000))
  }
}

# Best-effort pre-click rollback (page-contract section 21): exact-match clear at most once,
# then the same read-only bounded poll; changed content -> untouched; timeout -> failed.
# GATE3 section 7: the rollback ClearIfExact carries its own identity gate - when identity
# cannot be verified there is NO CLEAR and composer_rollback=failed (manual inspection
# required); identity is never relaxed just to clean up tool-authored text.
# Always exits with the ORIGINAL error plus a composer_rollback annotation.
function Wzb-PreclickRollback([string]$OrigCategory, [string]$OrigReason) {
  $rb = 'failed'
  $note = ''
  $convIdJson = ConvertTo-Json -InputObject $script:TargetId -Compress
  if (Wzb-EvalPageSoft $script:TargetUrl 'webgptPageComposerClearIfExact' @($convIdJson, $script:MsgJson)) {
    if ($script:WzbPageObj.ok -ne $true) {
      $cat = [string]$script:WzbPageObj.category
      if (-not $cat) { $cat = 'unknown' }
      $note = 'rollback could not verify conversation identity (' + $cat + '); manual inspection required'
    } else {
    $action = [string]$script:WzbPageObj.action
    if (-not $action) { $action = 'unknown' }
    switch ($action) {
      'cleared' {
        $prc = Wzb-PollComposerEmpty $script:TargetUrl
        if ($prc -eq 0)      { $rb = 'cleared'; $note = 'tool-authored composer text was safely cleared' }
        elseif ($prc -eq 1)  { $note = 'rollback clear executed once but composer did not become empty within ' + $script:ClearTimeoutS + 's; inspect manually' }
        else                 { $note = 'rollback empty-confirmation polling failed; inspect composer manually' }
      }
      'untouched' { $rb = 'untouched'; $note = 'composer changed; left untouched; inspect manually' }
      'skipped'   { $rb = 'skipped';   $note = 'composer unavailable during rollback; no destructive action' }
      default     { $note = 'pre-click rollback clear failed; composer may still contain tool-authored text; inspect manually' }
    }
    }
  } else {
    $note = 'pre-click rollback evaluation failed; composer may still contain tool-authored text; inspect manually'
  }
  Write-WzbErr ('pre-click rollback: ' + $note)
  Wzb-Fail $OrigCategory $OrigReason 1 @{ composer_rollback = $rb }
}

# ---------- send-ready polling (3s / 100ms; last round decides the category) ----------

function Wzb-PollSendReady {
  # NB: command-mode calls MUST be parenthesized before comparison/arithmetic,
  # otherwise '-ge' binds as a function argument and the deadline silently equals now.
  $deadline = (Get-WzbNow) + [int64]($script:BtnTimeoutS * [System.Diagnostics.Stopwatch]::Frequency)
  $exists = 'null'; $disabled = 'null'
  while ($true) {
    Wzb-EvalPage $script:TargetUrl 'webgptPageSendReady' @($script:MsgJson)
    Wzb-AssertTargetUnchanged
    Wzb-RequirePageOk
    if ([string]$script:WzbPageObj.ready -eq 'true') { return }
    $exists   = [string]$script:WzbPageObj.button_exists
    $disabled = [string]$script:WzbPageObj.button_disabled
    if ((Get-WzbNow) -ge $deadline) { break }
    Start-Sleep -Milliseconds ([int]($script:BtnIntervalS * 1000))
  }
  if ($exists -ne 'true') {
    Wzb-FailGuarded 'send_button_unavailable' ('send button not available within ' + $script:BtnTimeoutS + 's')
  }
  Wzb-FailGuarded 'send_button_disabled' ('send button still disabled within ' + $script:BtnTimeoutS + 's')
}

# ---------- target resolution ----------

function Wzb-ResolveTarget([string]$ConvFilter) {
  if ($ConvFilter) {
    $url = Wzb-FindPageUrlOrFail $ConvFilter
    if (-not $url) {
      Write-WzbErr ('target conversation tab not open; opening background tab https://chatgpt.com/c/' + $ConvFilter)
      Wzb-OpenPageOrFail ('https://chatgpt.com/c/' + $ConvFilter)
      Wzb-WaitReadiness $ConvFilter
      $url = $script:TargetUrl
    } else {
      $cid = ConvertFrom-WzbConvId $url
      if ($cid -cne $ConvFilter) {
        Wzb-Fail 'target_changed' ("matched tab resolved to '" + $(if ($cid) { $cid } else { 'none' }) + "', expected '$ConvFilter'")
      }
    }
    $script:TargetUrl = $url
    $script:TargetId  = $ConvFilter
  } else {
    $pages = Wzb-GetPagesOrFail
    # NB: never name this $matches - PowerShell's -match populates the automatic $Matches
    $convMatches = @()
    foreach ($p in $pages) {
      $u = [string]$p.url
      if (-not $u) { continue }
      $cid = ConvertFrom-WzbConvId $u
      if ($cid) { $convMatches += @{ url = $u; id = $cid } }
    }
    if ($convMatches.Count -eq 0) {
      Wzb-Fail 'no_webgpt_conversation_page' 'no open chatgpt.com tab resolves to /c/<id>; pass --conv <conversation-id>'
    }
    if ($convMatches.Count -gt 1) {
      Wzb-Fail 'ambiguous_target' ($convMatches.Count.ToString() + ' open conversation pages; pass --conv <conversation-id> to disambiguate')
    }
    $script:TargetUrl = [string]$convMatches[0].url
    $script:TargetId  = [string]$convMatches[0].id
  }
}

# Readiness poll after opening a tab (spec section 10: exact URL id + composer + auth; 30s / 500ms;
# GATE3: includes conversation identity - unverified identity keeps ready=false, and a final
# conversation_identity_unverified state maps to that stable category instead of composer_unavailable).
function Wzb-WaitReadiness([string]$ConvFilter) {
  $deadline = (Get-WzbNow) + [int64]($script:ReadyTimeoutS * [System.Diagnostics.Stopwatch]::Frequency)
  $url = ''; $ready = $false; $auth = $false; $idcat = ''
  $convIdJson = ConvertTo-Json -InputObject $ConvFilter -Compress
  while ($true) {
    $url = Wzb-FindPageUrlOrFail $ConvFilter
    if ($url) {
      $cid = ConvertFrom-WzbConvId $url
      if ($cid -ceq $ConvFilter) {
        if (Wzb-EvalPageSoft $url 'webgptPageReadiness' @($convIdJson)) {
          if ($script:WzbPageObj.ok -eq $true) {
            $ready = ([string]$script:WzbPageObj.ready -eq 'true')
            $auth  = ([string]$script:WzbPageObj.auth  -eq 'true')
            $idcat = [string]$script:WzbPageObj.identity_category
            if ($ready -and $auth) { break }
          }
        } else {
          # transport/eval errors during readiness polling surface the same way as cli.sh
          $f = $script:WzbEvalFail
          Wzb-Fail ($f -split '\|', 2)[0] ($(if (($f -split '\|', 2).Count -ge 2) { ($f -split '\|', 2)[1] } else { $f }))
        }
      }
    }
    if ((Get-WzbNow) -ge $deadline) { break }
    Start-Sleep -Milliseconds ([int]($script:ReadyIntervalS * 1000))
  }
  if (-not $url) {
    Wzb-Fail 'readiness_timeout' ('opened tab did not resolve to /c/' + $ConvFilter + ' within ' + $script:ReadyTimeoutS + 's')
  }
  $cid = ConvertFrom-WzbConvId $url
  if ($cid -cne $ConvFilter) {
    Wzb-Fail 'target_changed' ("opened tab finally resolved to '" + $(if ($cid) { $cid } else { 'none' }) + "', expected '$ConvFilter'")
  }
  # Final classification priority (GATE3-FIX1 section 5): target_changed > not_logged_in >
  # identity > composer - an explicit auth failure is never masked by identity/composer errors.
  if (-not $auth)  { Wzb-Fail 'not_logged_in' ('page auth not ready within ' + $script:ReadyTimeoutS + 's') }
  if (-not $ready -and $idcat -eq 'conversation_identity_unverified') {
    Wzb-Fail 'conversation_identity_unverified' ('opened tab did not prove conversation identity within ' + $script:ReadyTimeoutS + 's')
  }
  if (-not $ready) { Wzb-Fail 'composer_unavailable' ('composer #prompt-textarea not ready within ' + $script:ReadyTimeoutS + 's') }
  $script:TargetUrl = $url
}

# ---------- commands ----------

function Wzb-CmdList([string]$LimitArg) {
  $limit = $LimitArg
  if (-not $limit) { $limit = '28' }
  if ($limit -notmatch '^[0-9]+$') { Wzb-UsageFail ("limit must be an integer: $limit") }
  $n = [int]$limit
  if ($n -lt 1 -or $n -gt 100) { Wzb-UsageFail ("limit must be within 1..100: $limit") }
  Wzb-RunTransportInit
  Wzb-EvalPage '' 'webgptPageList' @(('"' + $limit + '"'))
  Wzb-RequirePageOk
  Write-WzbJsonLine $script:WzbPageResult
}

function Wzb-CmdFind([string]$Keyword) {
  if (-not $Keyword) { Wzb-UsageFail 'find requires <keyword>' }
  if ($Keyword -eq '') { Wzb-UsageFail 'keyword must be non-empty' }
  Wzb-RunTransportInit
  Wzb-EvalPage '' 'webgptPageFindList' @()
  Wzb-RequirePageOk
  # backend match: ordinal case-insensitive literal substring (spec section 19; never regex)
  $listMatch = @()
  foreach ($it in @($script:WzbPageObj.items)) {
    $title = [string]$it.title
    if ($title -and $title.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $copy = $it
      $copy | Add-Member -NotePropertyName source -NotePropertyValue 'list' -Force
      $listMatch += $copy
    }
  }
  $listIds = @()
  foreach ($m in $listMatch) { $listIds += [string]$m.id }
  # tab fallback: title literal match; only tabs whose URL resolves to /c/<id> enter results
  $tabJson = @()
  $pages = Wzb-GetPagesOrFail
  foreach ($p in $pages) {
    $t = [string]$p.title; $u = [string]$p.url
    if (-not $u) { continue }
    if ($t -and $t.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $cid = ConvertFrom-WzbConvId $u
      if ($cid) {
        $tabJson += [ordered]@{ id = $cid; title = $t; source = 'tab' }
      }
    }
  }
  # merge: backend-first; tabs only add ids the backend match did not produce (cli.sh parity)
  $out = @()
  $out += $listMatch
  foreach ($tb in $tabJson) {
    if ($listIds -notcontains [string]$tb.id) { $out += $tb }
  }
  Write-WzbJsonLine (ConvertTo-WzbJsonArray $out)
}

function Wzb-CheckConvId([string]$Id) {
  if ($Id -notmatch '^[A-Za-z0-9-]+$') { Wzb-UsageFail ("invalid conversation id: $Id") }
}

function Wzb-CmdConv([string]$Id) {
  if (-not $Id) { Wzb-UsageFail 'conv requires <conversation-id>' }
  Wzb-CheckConvId $Id
  Wzb-RunTransportInit
  Wzb-EvalPage '' 'webgptPageConvRaw' @(('"' + $Id + '"'))
  Wzb-RequirePageOk
  Write-WzbJsonLine ([string]$script:WzbPageObj.raw)
}

function Wzb-CmdTranscript([string]$Id) {
  if (-not $Id) { Wzb-UsageFail 'transcript requires <conversation-id>' }
  Wzb-CheckConvId $Id
  Wzb-RunTransportInit
  Wzb-EvalPage '' 'webgptPageTranscript' @(('"' + $Id + '"'))
  Wzb-RequirePageOk
  Write-WzbJsonLine $script:WzbPageResult
}

function Wzb-VerifyFail([string]$Category, [string]$Reason) {
  Wzb-Fail $Category $Reason 1 @{ sent = $true; clicked = $true; verified = $false }
}

function Wzb-InvokeSend([string[]]$Rest) {
  $doSend = 0; $doVerify = 0; $convFilter = ''; $msg = ''
  $i = 0
  while ($i -lt $Rest.Count) {
    $a = [string]$Rest[$i]
    switch ($a) {
      '--send'   { $doSend = 1 }
      '--verify' { $doVerify = 1 }
      '--conv'   {
        if ($i + 1 -ge $Rest.Count) { Wzb-UsageFail '--conv requires <conversation-id>' }
        $convFilter = [string]$Rest[$i + 1]; $i++
      }
      '-h'       { Wzb-UsageFail 'usage: send [--conv <id>] [--send] [--verify] "<message>"' }
      '--help'   { Wzb-UsageFail 'usage: send [--conv <id>] [--send] [--verify] "<message>"' }
      default    {
        if ($msg -ne '') { Wzb-UsageFail 'only one message argument allowed' }
        $msg = $a
      }
    }
    $i++
  }
  if ($msg -eq '') { Wzb-UsageFail 'message must be non-empty' }
  if ($doVerify -eq 1 -and $doSend -ne 1) { Wzb-UsageFail '--verify only allowed together with --send' }
  if ($convFilter) { Wzb-CheckConvId $convFilter }
  # PS string Length IS UTF-16 code units - identical to JavaScript string.length semantics
  # (surrogate pairs count as 2); asserted by the emoji-boundary contract tests.
  if ($msg.Length -gt 8000) { Wzb-UsageFail 'message exceeds 8000 characters' }

  $script:MsgJson = ConvertTo-Json -InputObject $msg -Compress

  $script:ComposerOwned     = 0
  $script:ClearPhaseStarted = 0
  $script:ClickAttempted    = 0

  Wzb-RunTransportInit
  Wzb-ResolveTarget $convFilter
  $convIdJson = ConvertTo-Json -InputObject $script:TargetId -Compress

  # 1) conversation identity atomic gate + composer precondition (must be empty) + write + exact readback
  #    (GATE3 section 6: identity proof and mutation happen inside the SAME Runtime.evaluate)
  Wzb-EvalPage $script:TargetUrl 'webgptPageSendPrecheck' @($convIdJson, $script:MsgJson)
  Wzb-AssertTargetUnchanged
  Wzb-RequirePageOk
  # write confirmed by exact readback -> composer text is owned by this command (section 21)
  $script:ComposerOwned = 1

  # 2) send-ready polling (separate evaluation; React state must not be assumed synchronous)
  Wzb-PollSendReady

  if ($doSend -eq 0) {
    # 3) dry-run: no click; section 16.1 exact ownership -> section 16.2 ONE mutation + read-only poll
    # explicit clear phase starts here: generic rollback disabled from now on (at most one clear)
    $script:ClearPhaseStarted = 1
    Wzb-EvalPage $script:TargetUrl 'webgptPageComposerClearIfExact' @($convIdJson, $script:MsgJson)
    Wzb-AssertTargetUnchanged
    Wzb-RequirePageOk
    $action = [string]$script:WzbPageObj.action
    if (-not $action) { $action = 'unknown' }
    switch ($action) {
      'cleared' {
        $prc = Wzb-PollComposerEmpty $script:TargetUrl
        if ($prc -eq 0) {
          Write-WzbJsonLine (ConvertTo-Json -InputObject ([ordered]@{ ok = $true; mode = 'dry-run'; conversation_id = $script:TargetId; send_ready = $true; cleared = $true }) -Compress)
          exit 0
        } elseif ($prc -eq 1) {
          Wzb-FailGuarded 'dry_run_clear_failure' ('clear executed once but composer did not become empty within ' + $script:ClearTimeoutS + 's; check the page manually')
        } else {
          Wzb-FailGuarded 'dry_run_clear_failure' 'composer state polling failed after clear; check the page manually'
        }
      }
      'untouched' { Wzb-FailGuarded 'composer_write_mismatch' 'composer changed before clear; left untouched; check the page manually' }
      'skipped'   { Wzb-FailGuarded 'composer_unavailable' 'composer unavailable before clear' }
      default     { Wzb-FailGuarded 'dry_run_clear_failure' ('unexpected clear action: ' + $action) }
    }
  }

  # ---- real --send path (Batch 4B: implemented + synthetic-tested only; no real execution) ----

  $preJson = ''
  if ($doVerify -eq 1) {
    # pre-click snapshot BEFORE the click (spec section 18.1)
    Wzb-EvalPage $script:TargetUrl 'webgptPageVerifySnapshot' @($convIdJson)
    Wzb-AssertTargetUnchanged
    Wzb-RequirePageOk
    $cn = $script:WzbPageObj.current_node
    $nids = @($script:WzbPageObj.node_ids)
    $shapeOk = ($null -ne $cn) -and ($cn -is [string]) -and ($cn.Length -gt 0) -and
               ($null -ne $script:WzbPageObj.node_ids) -and ($nids.Count -gt 0)
    if (-not $shapeOk) {
      Wzb-FailGuarded 'backend_parse_error' 'invalid verify pre-snapshot shape (current_node/node_ids); refusing to click'
    }
    $preJson = ConvertTo-Json -InputObject ([ordered]@{ current_node = [string]$cn; node_ids = $nids }) -Compress
  }

  # about to enter the click evaluation: from this moment automatic cleanup is permanently
  # disabled - whether the click actually happened can no longer be asserted (section 21.6)
  $script:ClickAttempted = 1
  # the ONE click evaluation (page atomically gates on conversation identity, then re-verifies
  # composer + button, then clicks once)
  Wzb-EvalPage $script:TargetUrl 'webgptPageSendClick' @($convIdJson, $script:MsgJson)
  Wzb-AssertTargetUnchanged
  Wzb-RequirePageOk

  if ($doVerify -eq 0) {
    Write-WzbJsonLine (ConvertTo-Json -InputObject ([ordered]@{ ok = $true; mode = 'send'; conversation_id = $script:TargetId; clicked = $true; verified = $null }) -Compress)
    exit 0
  }

  # verify polling: any failure/timeout never clicks again (section 18.4)
  $deadline = (Get-WzbNow) + [int64]($script:VerifyTimeoutS * [System.Diagnostics.Stopwatch]::Frequency)
  while ($true) {
    Wzb-EvalPage $script:TargetUrl 'webgptPageVerifyCheck' @($convIdJson, $preJson, $script:MsgJson)
    Wzb-AssertTargetUnchanged
    Wzb-RequirePageOk
    $status = [string]$script:WzbPageObj.status
    switch ($status) {
      'success' {
        $c = $script:WzbPageObj.candidate
        Write-WzbJsonLine (ConvertTo-Json -InputObject ([ordered]@{
          ok = $true; mode = 'send'; conversation_id = $script:TargetId
          clicked = $true; verified = $true
          message_id = [string]$c.message_id; create_time = $c.create_time
        }) -Compress)
        exit 0
      }
      'ambiguous'     { Wzb-VerifyFail 'verify_ambiguous' 'multiple new user messages exactly match the sent message' }
      'branch_changed'{ Wzb-VerifyFail 'verify_branch_changed' 'pre-send current_node no longer on post-send active branch' }
      'no_match'      {
        if ((Get-WzbNow) -ge $deadline) {
          Wzb-VerifyFail 'verify_timeout' 'send was clicked but backend confirmation was not observed before timeout'
        }
      }
      default         { Wzb-VerifyFail 'verify_timeout' ('unexpected verify status: ' + $status) }
    }
    Start-Sleep -Milliseconds ([int]($script:VerifyIntervalS * 1000))
  }
}

function Wzb-Main([string[]]$Argv) {
  if ($Argv.Count -lt 1) { Wzb-UsageFail 'missing command' }
  $cmd = [string]$Argv[0]
  $rest = @()
  if ($Argv.Count -gt 1) { $rest = $Argv[1..($Argv.Count - 1)] }
  switch ($cmd) {
    'list'       { Wzb-CmdList  ([string]$(if ($rest.Count -ge 1) { $rest[0] } else { '' })) }
    'find'       { Wzb-CmdFind  ([string]$(if ($rest.Count -ge 1) { $rest[0] } else { '' })) }
    'conv'       { Wzb-CmdConv  ([string]$(if ($rest.Count -ge 1) { $rest[0] } else { '' })) }
    'transcript' { Wzb-CmdTranscript ([string]$(if ($rest.Count -ge 1) { $rest[0] } else { '' })) }
    'send'       { Wzb-InvokeSend $rest }
    default      { Wzb-UsageFail ("unknown command: $cmd") }
  }
}

# ---------- load transport ----------
# Three transports expose the same five-function envelope interface:
#   WZB_TRANSPORT_DIR\transport.ps1  test mock (same injection convention as Bash);
#   broker-client.ps1                DEFAULT since Batch 5C: persistent per-user CDP
#                                    broker over an ACL'd named pipe, one long-lived
#                                    browser WebSocket shared across CLI invocations;
#   cdp-client.ps1                   legacy direct per-invocation WebSocket
#                                    (WZB_TRANSPORT_MODE=direct).
$script:WzbTransportFile =
  if ($env:WZB_TRANSPORT_DIR) { Join-Path $env:WZB_TRANSPORT_DIR 'transport.ps1' }
  elseif ($env:WZB_TRANSPORT_MODE -eq 'direct') { Join-Path $PSScriptRoot 'cdp-client.ps1' }
  else { Join-Path $PSScriptRoot 'broker-client.ps1' }

$script:WzbExitCode = 0
try {
  . $script:WzbTransportFile
  if (-not $env:WZB_SOURCE_ONLY) {
    Wzb-Main $args
  }
} catch {
  # last-resort: unexpected engine error outside the mapped failure paths
  $msg = [string]$_.Exception.Message
  Write-WzbErr ('internal error: ' + $msg)
  try { Write-WzbJsonLine (ConvertTo-WzbErrorJson 'internal_error' $msg $null) } catch {}
  $script:WzbExitCode = 1
} finally {
  if (Get-Command 'Invoke-WzbCleanup' -ErrorAction SilentlyContinue) { Invoke-WzbCleanup }
}
if (-not $env:WZB_SOURCE_ONLY) { exit $script:WzbExitCode }
