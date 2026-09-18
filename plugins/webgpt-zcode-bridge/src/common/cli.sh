# webgpt-zcode-bridge — common 命令编排（平台无关 bash；macOS 本轮为首个消费者）。
# 依据 spec/cli-contract.md 与 spec/page-contract.md 实现。
# 边界（ARCHITECTURE.md §2/§5）：
#   ChatGPT 业务语义（endpoint、投影、transcript、verify、composer 流程、错误类别）全部在本层与
#   src/common/page/*.js；transport 只提供 tab 枚举/打开/JS 执行与错误映射。
#   transport 通过 WZB_TRANSPORT_DIR 注入（测试可用 mock 替换）。
# 兼容 macOS 自带 bash 3.2（不使用 declare -A / ${var,,} / mapfile）。
#
# transport 函数契约（各平台实现必须满足；两种同构形态）：
#   stateless（macOS / contract mock）——结果走 stdout：
#     wzb_transport_init                       rc0 | rc1 + stdout "category|reason"
#     wzb_transport_list_pages                 rc0 + stdout "TITLE<TAB>URL" 行（仅 chatgpt.com）| rc1 同上
#     wzb_transport_find_page_url <conv_id>    rc0 + stdout URL（空=未找到）| rc1 同上
#     wzb_transport_open_page <url>            rc0 | rc1 同上
#     wzb_transport_eval <url_filter> <js>     rc0 + stdout "URL ||| RESULT" | rc1 同上
#   stateful（Linux persistent CDP）——transport 在 source 时设置 WZB_TRANSPORT_STATEFUL=1，
#     函数在当前 shell 执行（绝不得被 command substitution 放入 subshell，否则 helper 状态丢失），
#     结果经 global 返回：rc0 + WZB_TRANSPORT_OUT=payload | rc1 + WZB_TRANSPORT_OUT="category|reason"。
#   调用方一律经 wzb_tcall 调用 transport 函数，两种形态对上层完全同构。
#   （wzb_conv_id_from_url 由本文件在 source transport 前定义，transport 可复用该纯函数做精确 id 匹配）

WZB_PAGE_DIR="${WZB_PAGE_DIR:-${WZB_ROOT}/src/common/page}"

# 可调超时（秒；测试可通过环境变量缩短）
WZB_READY_TIMEOUT="${WZB_READY_TIMEOUT:-30}"
WZB_READY_INTERVAL="${WZB_READY_INTERVAL:-0.5}"
WZB_BTN_TIMEOUT="${WZB_BTN_TIMEOUT:-3}"
WZB_BTN_INTERVAL="${WZB_BTN_INTERVAL:-0.1}"
WZB_CLEAR_TIMEOUT="${WZB_CLEAR_TIMEOUT:-2}"
WZB_CLEAR_INTERVAL="${WZB_CLEAR_INTERVAL:-0.1}"
WZB_VERIFY_TIMEOUT="${WZB_VERIFY_TIMEOUT:-15}"
WZB_VERIFY_INTERVAL="${WZB_VERIFY_INTERVAL:-1}"

# ---------- 输出 / 失败 ----------

wzb_fail() { # <category> <reason> [exit_code=1] [extra_json_object]
  local cat="$1" rsn="$2" ec="${3:-1}" extra="${4:-}"
  local obj
  obj=$(jq -cn --arg c "$cat" --arg r "$rsn" --argjson e "${extra:-null}" \
    '{ok:false,category:$c,reason:$r} + ($e // {})')
  printf '%s\n' "$obj"
  exit "$ec"
}

wzb_usage_fail() {
  printf 'usage error: %s\n' "$1" >&2
  wzb_fail usage_error "$1" 2
}

# ---------- pre-click cleanup（spec/page-contract.md §21） ----------
# 状态变量（wzb_cmd_send 内设置）：
#   WZB_COMPOSER_OWNED=1      —— precheck 确认"写入且 readback 精确一致"，composer 文本为本命令所有；
#   WZB_CLEAR_PHASE_STARTED=1 —— dry-run 即将首次调用 ClearIfExact；从此禁用 generic rollback，
#                                保证 clear mutation 至多一次（§16.2），即使第一次 delete 未生效；
#   WZB_CLICK_ATTEMPTED=1     —— 即将进入 send click evaluation，从此永久禁用自动 cleanup。

# 失败出口的 cleanup 门控：仅在 owned、未尝试 click、且显式 clear 阶段尚未开始的窗口内
# 先做 best-effort rollback，然后以原始错误退出；rollback 结果绝不掩盖原始 category（spec §21 + 原始错误优先）。
wzb_fail_guarded() { # <category> <reason> [exit_code=1] [extra_json]
  if [ "${WZB_COMPOSER_OWNED:-0}" -eq 1 ] && [ "${WZB_CLICK_ATTEMPTED:-0}" -eq 0 ] && [ "${WZB_CLEAR_PHASE_STARTED:-0}" -eq 0 ]; then
    wzb_preclick_rollback "$1" "$2"
  fi
  wzb_fail "$1" "$2" "${3:-1}" "${4:-}"
}

# 只读有界轮询 canonical composer 直到空串（spec §16.2：100ms / 2s，期间绝不重复 clear mutation）。
# 返回：0=确认空串；1=timeout；2=evaluation error。
wzb_poll_composer_empty() { # <url_filter>
  local max it exists text
  max=$(awk -v t="$WZB_CLEAR_TIMEOUT" -v i="$WZB_CLEAR_INTERVAL" 'BEGIN{printf "%d", (t/i)+0.5}')
  it=0
  while :; do
    if ! wzb_eval_page_soft "$1" webgptPageComposerState; then return 2; fi
    exists=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.exists // false')
    text=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.text // "__missing__"')
    if [ "$exists" = "true" ] && [ "$text" = "" ]; then return 0; fi
    it=$((it+1))
    if [ "$it" -ge "$max" ]; then return 1; fi
    sleep "$WZB_CLEAR_INTERVAL"
  done
}

# best-effort rollback（spec §21.2-21.6 + §22）：exact-match 後 clear mutation 至多一次，
# 之后用 §16.2 相同的只读有界轮询确认空串；内容已变化 → untouched；timeout/失败不再第二次 clear。
# §7（GATE3）：rollback 的 ClearIfExact 自带 identity gate——identity 无法验证时不 clear，
# composer_rollback=failed + manual inspection required（不为清理工具文本放宽 identity）。
# 本函数必定退出（wzb_fail 原始错误 + composer_rollback 附注）。
wzb_preclick_rollback() { # <orig_category> <orig_reason>
  local note rb rc prc conv_json
  conv_json=$(jq -cn --arg i "${WZB_TARGET_ID}" '$i')
  set +e
  wzb_eval_page_soft "$WZB_TARGET_URL" webgptPageComposerClearIfExact "$conv_json" "$MSG_JSON"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rb=failed
    note="pre-click rollback evaluation failed; composer may still contain tool-authored text; inspect manually"
  elif [ "$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.ok // empty')" != "true" ]; then
    rb=failed
    note="rollback could not verify conversation identity ($(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.category // "unknown"')); manual inspection required"
  else
    rb=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.action // "unknown"')
    case "$rb" in
      cleared)
        # mutation 已执行一次；只读轮询异步确认，绝不再次 delete（§21.4/§21.6）
        # || 捕获防止轮询超时返回值触发 errexit
        prc=0
        wzb_poll_composer_empty "$WZB_TARGET_URL" || prc=$?
        if [ "$prc" -eq 0 ]; then
          note="tool-authored composer text was safely cleared"
        elif [ "$prc" -eq 1 ]; then
          rb=failed
          note="rollback clear executed once but composer did not become empty within ${WZB_CLEAR_TIMEOUT}s; inspect manually"
        else
          rb=failed
          note="rollback empty-confirmation polling failed; inspect composer manually"
        fi
        ;;
      untouched) note="composer changed; left untouched; inspect manually" ;;
      skipped)   note="composer unavailable during rollback; no destructive action" ;;
      *)         rb=failed; note="pre-click rollback clear failed; composer may still contain tool-authored text; inspect manually" ;;
    esac
  fi
  printf 'pre-click rollback: %s\n' "$note" >&2
  wzb_fail "$1" "$2" 1 "{\"composer_rollback\":\"$rb\"}"
}

# ---------- URL → conversation id（spec §9 + target-binding hardening 2026-09-14） ----------
# 语义与 Windows Test-WzbWebgptUrl/ConvertFrom-WzbConvId 一致：
#   1. origin 门槛：仅 https://chatgpt.com（host 精确相等；端口为 HTTPS 默认——缺省或显式 :443）；
#      lookalike host（chatgpt.com.evil.example / chatgpt.com@evil）、非 https、非默认端口 → 一律空。
#   2. conversation id 只从 URL 的 pathname 段 /c/<id> 解析（支持 /g/.../c/<id> 项目形态）；
#      query/fragment 中出现的 "/c/..." 永不生效（如 ?next=/c/abc、#/c/abc）。
#   3. <id> 段字符集 [A-Za-z0-9-]+（整段语义：段内出现其它字符则该 /c/ 不匹配）。
# 纯 Bash 实现（macOS bash 3.2 兼容，不引入新 runtime）。

wzb_conv_id_from_url() {
  local url="$1"
  case "$url" in
    https://chatgpt.com/*)      url="${url#https://chatgpt.com}" ;;
    https://chatgpt.com:443/*)  url="${url#https://chatgpt.com:443}" ;;
    *) printf ''; return 0 ;;
  esac
  # 截断 query 与 fragment：conversation id 只允许来自 pathname
  url="${url%%\?*}"
  url="${url%%#*}"
  local re='/c/([A-Za-z0-9-]+)(/|$)'
  [[ "$url" =~ $re ]] || { printf ''; return 0; }
  printf '%s' "${BASH_REMATCH[1]}"
}

# ---------- 页面 evaluation（bundle = common page JS + 入口函数 + JSON 参数） ----------

wzb_page_files() {
  case "$1" in
    webgptPageList|webgptPageFindList) printf 'auth.js conversations.js' ;;
    webgptPageConvRaw|webgptPageTranscript) printf 'auth.js transcript.js conversation.js' ;;
    webgptPageVerifySnapshot|webgptPageVerifyCheck) printf 'auth.js transcript.js verify.js conversation.js' ;;
    webgptPageReadiness) printf 'auth.js identity.js composer.js' ;;
    webgptPageSendPrecheck|webgptPageComposerClearIfExact|webgptPageSendClick)
      printf 'auth.js transcript.js identity.js composer.js' ;;
    webgptPageSendReady|webgptPageComposerState) printf 'auth.js composer.js' ;;
    *) return 1 ;;
  esac
}

# wzb_eval_page_soft：与 wzb_eval_page 相同，但失败不直接退出；
# rc=1 时 WZB_EVAL_FAIL="category|reason"（供 rollback 等需要保留原始错误的调用方使用）。
# 注意：不得用 set +e/set -e 切换包裹失败 return——嵌套调用会破坏调用方的 -e 状态；
# 统一用 if 条件上下文豁免 errexit。
wzb_eval_page_soft() {
  local filter="$1" entry="$2"; shift 2
  local files f js args a
  files=$(wzb_page_files "$entry") || { WZB_EVAL_FAIL="transport_failure|unknown page entry: $entry"; return 1; }
  js=''
  for f in $files; do
    js="${js}$(cat "${WZB_PAGE_DIR}/${f}")
"
  done
  args=''
  for a in "$@"; do args="${args}${a},"; done
  args="${args%,}"
  local wrapper
  wrapper="(function(){try{return JSON.stringify(${entry}.apply(null,[${args}]))}catch(e){return JSON.stringify({ok:false,category:'page_runtime_error',reason:String(e)})}})()"
  if wzb_tcall wzb_transport_eval "$filter" "${js}${wrapper}"; then
    WZB_TAB_URL="${WZB_TRANSPORT_OUT%% ||| *}"
    WZB_PAGE_RESULT="${WZB_TRANSPORT_OUT#* ||| }"
    return 0
  fi
  WZB_EVAL_FAIL="$WZB_TRANSPORT_OUT"
  return 1
}

# wzb_eval_page <url_filter> <entry_fn> [args_json ...]
# 成功后：WZB_TAB_URL=执行页 URL；WZB_PAGE_RESULT=页面返回的 JSON envelope（单行）。
wzb_eval_page() {
  wzb_eval_page_soft "$@" || wzb_fail_guarded "${WZB_EVAL_FAIL%%|*}" "${WZB_EVAL_FAIL#*|}"
}

# 页面 envelope ok 检查；失败时透传 category/reason 并 exit 1（send 窗口内先 rollback）。
wzb_require_page_ok() {
  if [ "$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.ok // empty')" != "true" ]; then
    wzb_fail_guarded \
      "$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.category // "page_runtime_error"')" \
      "$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.reason // "page evaluation failed"')" \
      1
  fi
}

# send 流程中每次 evaluation 后复核目标页未变（spec §14：任一变化立即失败）。
wzb_assert_target_unchanged() {
  local cid
  cid=$(wzb_conv_id_from_url "$WZB_TAB_URL")
  [ "$cid" = "$WZB_TARGET_ID" ] || wzb_fail_guarded target_changed "executing page resolved to conversation '${cid:-none}', expected '$WZB_TARGET_ID'"
}

# ---------- 统一 transport 调用入口（stateless/stateful 同构） ----------
# stateless：command substitution 捕获 stdout → WZB_TRANSPORT_OUT（macOS AppleScript / contract mock）。
# stateful：在当前 shell 执行函数，由函数直接设置 WZB_TRANSPORT_OUT（Linux persistent CDP），
#   确保 helper PID/FD 等 shell 状态在整个 CLI invocation 存续（不进 command-substitution subshell）。
# 两种形态失败时均为 WZB_TRANSPORT_OUT="category|reason" + rc1。
# 调用点统一形如：wzb_tcall wzb_transport_* ... || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
wzb_tcall() { # <fn> [args...]
  WZB_TRANSPORT_OUT=''
  if [ "${WZB_TRANSPORT_STATEFUL:-0}" -eq 1 ]; then
    "$@"
  else
    WZB_TRANSPORT_OUT=$("$@")
  fi
}

# ---------- transport 装载（cli 先定义纯函数，transport 可复用） ----------

. "${WZB_TRANSPORT_DIR}/transport.sh"

# ---------- 校验助手 ----------

wzb_check_conv_id() { # <id> → 合法则静默，否则 usage exit 2
  local re='^[A-Za-z0-9-]+$'
  [[ "$1" =~ $re ]] || wzb_usage_fail "invalid conversation id: $1"
}

# UTF-16 code unit 精确计数（emoji 等占 2）；与 JavaScript string.length 同义。
wzb_utf16_len() {
  jq -Rn --arg s "$1" '$s | explode | length + ([.[] | select(. > 65535)] | length)'
}

# ---------- send：目标解析 ----------

# 结果：WZB_TARGET_URL / WZB_TARGET_ID
wzb_resolve_target() {
  if [ -n "$CONV_FILTER" ]; then
    local url cid
    wzb_tcall wzb_transport_find_page_url "$CONV_FILTER" || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
    url="$WZB_TRANSPORT_OUT"
    if [ -z "$url" ]; then
      printf 'target conversation tab not open; opening background tab https://chatgpt.com/c/%s\n' "$CONV_FILTER" >&2
      wzb_tcall wzb_transport_open_page "https://chatgpt.com/c/${CONV_FILTER}" || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
      wzb_wait_readiness
      url="$WZB_TARGET_URL"
    else
      cid=$(wzb_conv_id_from_url "$url")
      [ "$cid" = "$CONV_FILTER" ] || wzb_fail target_changed "matched tab resolved to '${cid:-none}', expected '$CONV_FILTER'"
    fi
    WZB_TARGET_URL="$url"
    WZB_TARGET_ID="$CONV_FILTER"
  else
    local pages t u cid matches n
    wzb_tcall wzb_transport_list_pages || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
    pages="$WZB_TRANSPORT_OUT"
    matches=''; n=0
    while IFS=$'\t' read -r t u; do
      [ -n "$u" ] || continue
      cid=$(wzb_conv_id_from_url "$u")
      if [ -n "$cid" ]; then
        matches="${matches}${u}"$'\t'"${cid}"$'\n'
        n=$((n+1))
      fi
    done <<< "$pages"
    if [ "$n" -eq 0 ]; then
      wzb_fail no_webgpt_conversation_page "no open chatgpt.com tab resolves to /c/<id>; pass --conv <conversation-id>"
    elif [ "$n" -gt 1 ]; then
      wzb_fail ambiguous_target "$n open conversation pages; pass --conv <conversation-id> to disambiguate"
    fi
    WZB_TARGET_URL="${matches%%$'\t'*}"
    WZB_TARGET_ID="${matches#*$'\t'}"
    WZB_TARGET_ID="${WZB_TARGET_ID%%$'\n'*}"
  fi
}

# 打开新标签页后的 readiness 轮询（spec §10：URL id 精确 + composer + 认证；30s/0.5s；
# GATE3 起含 conversation identity——identity 未验证 → ready=false）。
wzb_wait_readiness() {
  local deadline=$((SECONDS + WZB_READY_TIMEOUT))
  local url='' cid ready=0 auth=0 idcat=''
  local conv_json
  conv_json=$(jq -cn --arg i "$CONV_FILTER" '$i')
  while [ "$SECONDS" -lt "$deadline" ]; do
    wzb_tcall wzb_transport_find_page_url "$CONV_FILTER" || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
    url="$WZB_TRANSPORT_OUT"
    if [ -n "$url" ]; then
      cid=$(wzb_conv_id_from_url "$url")
      if [ "$cid" = "$CONV_FILTER" ]; then
        wzb_eval_page "$url" webgptPageReadiness "$conv_json"
        if [ "$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.ok // empty')" = "true" ]; then
          ready=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.ready')
          auth=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.auth')
          idcat=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.identity_category // empty')
          [ "$ready" = "true" ] && [ "$auth" = "true" ] && break
        fi
      fi
    fi
    sleep "$WZB_READY_INTERVAL"
  done
  if [ -z "$url" ]; then
    wzb_fail readiness_timeout "opened tab did not resolve to /c/${CONV_FILTER} within ${WZB_READY_TIMEOUT}s"
  fi
  cid=$(wzb_conv_id_from_url "$url")
  if [ "$cid" != "$CONV_FILTER" ]; then
    wzb_fail target_changed "opened tab finally resolved to '${cid:-none}', expected '$CONV_FILTER'"
  fi
  # 最终分类优先级（GATE3-FIX1 §5）：target_changed > not_logged_in > identity > composer，
  # 确保明确 auth 失败不被 identity/composer 错误覆盖。
  [ "$auth" = "true" ] || wzb_fail not_logged_in "page auth not ready within ${WZB_READY_TIMEOUT}s"
  if [ "$ready" != "true" ] && [ "$idcat" = "conversation_identity_unverified" ]; then
    wzb_fail conversation_identity_unverified "opened tab did not prove conversation identity within ${WZB_READY_TIMEOUT}s"
  fi
  [ "$ready" = "true" ] || wzb_fail composer_unavailable "composer #prompt-textarea not ready within ${WZB_READY_TIMEOUT}s"
  WZB_TARGET_URL="$url"
}

# ---------- 命令实现 ----------

wzb_cmd_list() {
  local limit="${1:-28}"
  local re='^[0-9]+$'
  [[ "$limit" =~ $re ]] || wzb_usage_fail "limit must be an integer: $limit"
  [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] || wzb_usage_fail "limit must be within 1..100: $limit"
  wzb_run_transport_init
  wzb_eval_page '' webgptPageList "$limit"
  wzb_require_page_ok
  printf '%s\n' "$WZB_PAGE_RESULT"
}

wzb_cmd_find() {
  [ $# -ge 1 ] || wzb_usage_fail "find requires <keyword>"
  local kw="$1"
  [ -n "$kw" ] || wzb_usage_fail "keyword must be non-empty"
  wzb_run_transport_init
  wzb_eval_page '' webgptPageFindList
  wzb_require_page_ok
  local list_items
  list_items=$(printf '%s' "$WZB_PAGE_RESULT" | jq -c '.items')
  wzb_tcall wzb_transport_list_pages || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
  local pages
  pages="$WZB_TRANSPORT_OUT"
  # backend 匹配：jq contains = 字面子串；ascii_downcase 实现大小写不敏感（spec §19，永不按正则解释）
  local list_match
  list_match=$(jq -cn --arg kw "$kw" --argjson items "$list_items" \
    '$items | map(select(((.title // "") | ascii_downcase) | contains(($kw | ascii_downcase)))) | map(. + {source:"list"})')
  # tab 兜底：标题 grep -F 字面匹配；仅 URL 可解析出 /c/<id> 的 tab 进入结果
  local t u cid tab_json
  tab_json='[]'
  while IFS=$'\t' read -r t u; do
    [ -n "$u" ] || continue
    if printf '%s' "$t" | grep -qiF -- "$kw"; then
      cid=$(wzb_conv_id_from_url "$u")
      if [ -n "$cid" ]; then
        tab_json=$(jq -cn --argjson a "$tab_json" --arg id "$cid" --arg ti "$t" '$a + [{id:$id,title:$ti,source:"tab"}]')
      fi
    fi
  done <<< "$pages"
  # 合并去重：backend 结果优先，tab 只补 backend 未出现的 id（spec §19）
  jq -cn --argjson l "$list_match" --argjson t "$tab_json" \
    '$l + ($t | map(. as $tb | select(($l | map(.id) | index($tb.id)) | not)))'
}

wzb_cmd_conv() {
  [ $# -ge 1 ] || wzb_usage_fail "conv requires <conversation-id>"
  local id="$1"
  wzb_check_conv_id "$id"
  wzb_run_transport_init
  wzb_eval_page '' webgptPageConvRaw "\"$id\""
  wzb_require_page_ok
  printf '%s' "$WZB_PAGE_RESULT" | jq -r '.raw'
  printf '\n'
}

wzb_cmd_transcript() {
  [ $# -ge 1 ] || wzb_usage_fail "transcript requires <conversation-id>"
  local id="$1"
  wzb_check_conv_id "$id"
  wzb_run_transport_init
  wzb_eval_page '' webgptPageTranscript "\"$id\""
  wzb_require_page_ok
  printf '%s\n' "$WZB_PAGE_RESULT"
}

wzb_run_transport_init() {
  wzb_tcall wzb_transport_init || wzb_fail "${WZB_TRANSPORT_OUT%%|*}" "${WZB_TRANSPORT_OUT#*|}"
}

wzb_poll_send_ready() { # 轮询 send-ready；失败 exit 1（button 缺失/禁用取最后一轮状态定类别）
  local iters max it rv
  max=$(awk -v t="$WZB_BTN_TIMEOUT" -v i="$WZB_BTN_INTERVAL" 'BEGIN{printf "%d", (t/i)+0.5}')
  it=0
  local exists='null' disabled='null'
  while :; do
    wzb_eval_page "$WZB_TARGET_URL" webgptPageSendReady "$MSG_JSON"
    wzb_assert_target_unchanged
    wzb_require_page_ok
    rv=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.ready')
    exists=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.button_exists')
    disabled=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.button_disabled')
    [ "$rv" = "true" ] && return 0
    it=$((it+1))
    if [ "$it" -ge "$max" ]; then break; fi
    sleep "$WZB_BTN_INTERVAL"
  done
  if [ "$exists" != "true" ]; then
    wzb_fail_guarded send_button_unavailable "send button not available within ${WZB_BTN_TIMEOUT}s"
  fi
  wzb_fail_guarded send_button_disabled "send button still disabled within ${WZB_BTN_TIMEOUT}s"
}

wzb_verify_fail() { # <category> <reason> —— verify 阶段失败统一带 sent/clicked/verified 标记（spec §10.2/§18.4）
  wzb_fail "$1" "$2" 1 '{"sent":true,"clicked":true,"verified":false}'
}

wzb_cmd_send() {
  local DO_SEND=0 DO_VERIFY=0 CONV_FILTER='' MSG=''
  while [ $# -ge 1 ]; do
    case "$1" in
      --send) DO_SEND=1 ;;
      --verify) DO_VERIFY=1 ;;
      --conv)
        [ $# -ge 2 ] || wzb_usage_fail "--conv requires <conversation-id>"
        CONV_FILTER="$2"; shift ;;
      -h|--help) wzb_usage_fail 'usage: send [--conv <id>] [--send] [--verify] "<message>"' ;;
      *) [ -z "$MSG" ] || wzb_usage_fail 'only one message argument allowed'; MSG="$1" ;;
    esac
    shift
  done
  [ -n "$MSG" ] || wzb_usage_fail 'message must be non-empty'
  [ "$DO_VERIFY" -eq 0 ] || [ "$DO_SEND" -eq 1 ] || wzb_usage_fail '--verify only allowed together with --send'
  [ -z "$CONV_FILTER" ] || wzb_check_conv_id "$CONV_FILTER"
  # 消息长度上限 8000 UTF-16 code units（spec §9；与 JavaScript string.length 同义）
  [ "$(wzb_utf16_len "$MSG")" -le 8000 ] || wzb_usage_fail 'message exceeds 8000 characters'
  # 原始消息的标准 JSON 序列化（spec §12：不使用手写多层 quote escaping）
  local MSG_JSON PRE_JSON='' CONV_ID_JSON
  MSG_JSON=$(jq -cn --arg m "$MSG" '$m')

  # pre-click cleanup 状态（spec §21 + §16.2）：owned 前不自动清理；显式 clear 阶段开始后
  # 不再 generic rollback（clear mutation 至多一次）；click 尝试后永久禁用自动清理
  WZB_COMPOSER_OWNED=0
  WZB_CLEAR_PHASE_STARTED=0
  WZB_CLICK_ATTEMPTED=0

  wzb_run_transport_init
  wzb_resolve_target
  CONV_ID_JSON=$(jq -cn --arg i "$WZB_TARGET_ID" '$i')

  # 1) conversation identity 原子 gate + composer 前置（必须为空）+ 写入 + 精确 readback
  #    （§22：identity proof 与 mutation 在同一 Runtime.evaluate 内完成）
  wzb_eval_page "$WZB_TARGET_URL" webgptPageSendPrecheck "$CONV_ID_JSON" "$MSG_JSON"
  wzb_assert_target_unchanged
  wzb_require_page_ok
  # 写入且 readback 精确一致 → composer 文本自此为本命令所有（spec §21 owned）
  WZB_COMPOSER_OWNED=1

  # 2) send-ready 轮询（独立 evaluation；不假设同一 evaluate 内 React 已更新）
  wzb_poll_send_ready

  if [ "$DO_SEND" -eq 0 ]; then
    # 3) dry-run：不 click；§16.1 exact ownership → §16.2 单次 mutation + 只读轮询异步确认
    # 显式 clear 阶段开始：此后任何失败都不再进入 generic rollback（clear mutation 至多一次）
    WZB_CLEAR_PHASE_STARTED=1
    wzb_eval_page "$WZB_TARGET_URL" webgptPageComposerClearIfExact "$CONV_ID_JSON" "$MSG_JSON"
    wzb_assert_target_unchanged
    wzb_require_page_ok
    local clear_action clear_prc
    clear_action=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.action // "unknown"')
    case "$clear_action" in
      cleared)
        clear_prc=0
        wzb_poll_composer_empty "$WZB_TARGET_URL" || clear_prc=$?
        if [ "$clear_prc" -eq 0 ]; then
          jq -cn --arg cid "$WZB_TARGET_ID" '{ok:true,mode:"dry-run",conversation_id:$cid,send_ready:true,cleared:true}'
          exit 0
        elif [ "$clear_prc" -eq 1 ]; then
          wzb_fail_guarded dry_run_clear_failure "clear executed once but composer did not become empty within ${WZB_CLEAR_TIMEOUT}s; check the page manually"
        else
          wzb_fail_guarded dry_run_clear_failure "composer state polling failed after clear; check the page manually"
        fi
        ;;
      untouched)
        wzb_fail_guarded composer_write_mismatch "composer changed before clear; left untouched; check the page manually"
        ;;
      skipped)
        wzb_fail_guarded composer_unavailable "composer unavailable before clear"
        ;;
      *)
        wzb_fail_guarded dry_run_clear_failure "unexpected clear action: $clear_action"
        ;;
    esac
  fi

  # ---- 以下为 --send 真实路径（本轮仅实现与 fixture 测试，动态验证禁止进入） ----

  if [ "$DO_VERIFY" -eq 1 ]; then
    # pre-click 快照先于 click（spec §18.1）
    wzb_eval_page "$WZB_TARGET_URL" webgptPageVerifySnapshot "$CONV_ID_JSON"
    wzb_assert_target_unchanged
    wzb_require_page_ok
    # snapshot shape 校验：current_node 非空 string、node_ids 非空 array；
    # 不合法在 click 前失败（映射为既有 backend_parse_error，不新增 category）
    if ! printf '%s' "$WZB_PAGE_RESULT" | jq -e \
      '(.current_node | type) == "string" and (.current_node | length > 0) and (.node_ids | type) == "array" and (.node_ids | length > 0)' >/dev/null; then
      wzb_fail_guarded backend_parse_error "invalid verify pre-snapshot shape (current_node/node_ids); refusing to click"
    fi
    PRE_JSON=$(printf '%s' "$WZB_PAGE_RESULT" | jq -c '{current_node:.current_node,node_ids:.node_ids}')
  fi

  # 即将进入 click evaluation：从此刻起 click 是否实际发生不可靠断言，永久禁用自动 cleanup（spec §21.6）
  WZB_CLICK_ATTEMPTED=1
  # click（页面内原子 identity gate + composer/按钮复核后唯一一次 click；每命令进程最多一次）
  wzb_eval_page "$WZB_TARGET_URL" webgptPageSendClick "$CONV_ID_JSON" "$MSG_JSON"
  wzb_assert_target_unchanged
  wzb_require_page_ok

  if [ "$DO_VERIFY" -eq 0 ]; then
    jq -cn --arg cid "$WZB_TARGET_ID" '{ok:true,mode:"send",conversation_id:$cid,clicked:true,verified:null}'
    exit 0
  fi

  # verify 轮询：任何失败/超时都不再第二次 click（spec §18.4）
  local deadline=$((SECONDS + WZB_VERIFY_TIMEOUT))
  local status
  while :; do
    wzb_eval_page "$WZB_TARGET_URL" webgptPageVerifyCheck "$CONV_ID_JSON" "$PRE_JSON" "$MSG_JSON"
    wzb_assert_target_unchanged
    wzb_require_page_ok
    status=$(printf '%s' "$WZB_PAGE_RESULT" | jq -r '.status')
    case "$status" in
      success)
        jq -cn --arg cid "$WZB_TARGET_ID" \
          --argjson c "$(printf '%s' "$WZB_PAGE_RESULT" | jq -c '.candidate')" \
          '{ok:true,mode:"send",conversation_id:$cid,clicked:true,verified:true,message_id:$c.message_id,create_time:$c.create_time}'
        exit 0
        ;;
      ambiguous) wzb_verify_fail verify_ambiguous 'multiple new user messages exactly match the sent message' ;;
      branch_changed) wzb_verify_fail verify_branch_changed 'pre-send current_node no longer on post-send active branch' ;;
      no_match)
        if [ "$SECONDS" -ge "$deadline" ]; then
          wzb_verify_fail verify_timeout "send was clicked but backend confirmation was not observed before timeout"
        fi
        sleep "$WZB_VERIFY_INTERVAL"
        ;;
      *) wzb_verify_fail verify_timeout "unexpected verify status: $status" ;;
    esac
  done
}

# ---------- 入口 ----------

wzb_main() {
  [ $# -ge 1 ] || wzb_usage_fail 'missing command'
  local cmd="$1"; shift
  case "$cmd" in
    list) wzb_cmd_list "$@" ;;
    find) wzb_cmd_find "$@" ;;
    conv) wzb_cmd_conv "$@" ;;
    transcript) wzb_cmd_transcript "$@" ;;
    send) wzb_cmd_send "$@" ;;
    *) wzb_usage_fail "unknown command: $cmd" ;;
  esac
}
