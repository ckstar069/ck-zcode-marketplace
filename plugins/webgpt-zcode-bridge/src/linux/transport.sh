# webgpt-zcode-bridge — Linux direct CDP transport（stateful，persistent helper）。
# 职责边界（ARCHITECTURE.md §5/§7）：真实 Chrome 检测、DevToolsActivePort 校验、
# 持久 Node helper 生命周期、5 个 wzb_transport_* 契约函数、错误映射、cleanup。
# 不包含：ChatGPT endpoint、backend schema、token、composer/verify 语义（都在 common 层）。
#
# lifecycle（Batch 5C）：one CLI invocation = one broker-client（coproc），
#   多个 CLI invocation 共享 per-user 持久 cdp-broker（UDS）→ one long-lived browser WebSocket。
#   broker 由 broker-client 按需拉起（单例锁防 duplicate），browser WS 无 idle timeout；
#   本 CLI 退出只关闭自己的 client 连接，绝不 shutdown 共享 broker。
#   WZB_CDP_DIRECT=1 回退 legacy 直连模式（one-shot cdp-client = 本 invocation 一条 browser WS）。
#   init 仍为真实健康检查（经 broker 真实建连 + Browser.getVersion——"文件存在"不等于健康）。
#
# stateful 契约：本文件 source 时声明 WZB_TRANSPORT_STATEFUL=1；
#   函数在当前 shell 执行（由 cli.sh 的 wzb_tcall 保证不被 command substitution 放入 subshell），
#   成功 rc0 + WZB_TRANSPORT_OUT=payload；失败 rc1 + WZB_TRANSPORT_OUT="category|reason"。
#
# 仅支持 Linux bash ≥4（coproc/declare -g；本文件不被 macOS source）。
# JS 经 stdin 管道进入 helper，不进 node argv / 进程列表 / 临时文件（用户消息正文保护）。

WZB_TRANSPORT_STATEFUL=1

WZB_LINUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认 broker 模式；WZB_CDP_DIRECT=1 → legacy 直连 one-shot helper
if [ "${WZB_CDP_DIRECT:-0}" -eq 1 ]; then
  WZB_CDP_CLIENT="${WZB_CDP_CLIENT:-$WZB_LINUX_DIR/cdp-client.mjs}"
else
  WZB_CDP_CLIENT="${WZB_CDP_CLIENT:-$WZB_LINUX_DIR/broker-client.mjs}"
fi
# 连接超时默认 90s：Chrome 对每一条新 browser WebSocket 连接都弹 Allow 框等用户点击
# （2026-09-12 用户确认：每次连接都要手动授权，非仅 Chrome 重启后首次；未点即挂起）。
WZB_CDP_CONNECT_TIMEOUT="${WZB_CDP_CONNECT_TIMEOUT:-90}"
# broker 冷启动的有界等待（秒；仅在 ping 不到健康 broker 时发生）。
WZB_CDP_BROKER_START_TIMEOUT="${WZB_CDP_BROKER_START_TIMEOUT:-15}"
# 单个 eval 响应上限（页面内含同步 XHR 的 backend 调用）。
WZB_CDP_READ_TIMEOUT="${WZB_CDP_READ_TIMEOUT:-60}"

# helper 生命周期自有变量（coproc 变量在进程退出时会被 bash unset，不可依赖）
WZB_HELPER_PID=''
WZB_HELPER_RFD=''
WZB_HELPER_WFD=''
WZB_CDP_SEQ=0
WZB_CDP_CLEANED=0

wzb_t_fail() { # stateful 错误：WZB_TRANSPORT_OUT="category|reason" + rc1
  WZB_TRANSPORT_OUT="$1|$2"
  return 1
}

# 只清理本 CLI 自己启动的 helper（自己的 PID/FD 变量）；绝不 pkill/killall、绝不触碰 Chrome。
# 注意：bash 在 coproc 进程退出时会 unset 掉 coproc 关联变量（WZB_CDP / WZB_CDP_PID，
# 含预声明的全局），因此 helper PID/FD 一律使用下方自有的 WZB_HELPER_* 普通变量，
# 不在 helper 存活期之外引用任何 coproc 变量（2026-09-12 动态实测定位）。
wzb_linux_kill_helper() {
  if [ -n "$WZB_HELPER_PID" ]; then
    kill -TERM "$WZB_HELPER_PID" 2>/dev/null || true
    wait "$WZB_HELPER_PID" 2>/dev/null || true
    WZB_HELPER_PID=''
  fi
}

# EXIT trap：优雅 shutdown → 有限等待 → TERM 兜底；幂等（只执行一次）。
# 不调用 Browser.close / Target.closeTarget；helper 退出即 WebSocket 关闭、Chrome 自动 detach。
wzb_linux_cleanup() {
  [ "$WZB_CDP_CLEANED" -eq 1 ] && return 0
  WZB_CDP_CLEANED=1
  # 只终止本 CLI 自己的 client 进程（broker 模式下 client 是 IPC 适配器，TERM 即断开；
  # 绝不向共享 broker 转发 shutdown op——那是显式本地维护操作，不属于普通 CLI 退出）。
  wzb_linux_kill_helper
}

# 串行 line-JSON 请求/响应；响应必须与请求 id 严格关联（防串线/半协议行）。
wzb_cdp_request() { # <req_json_without_id> [read_timeout_sec]
  WZB_CDP_RESP=''
  WZB_CDP_SEQ=$((WZB_CDP_SEQ + 1))
  local id="$WZB_CDP_SEQ" tmo="${2:-$WZB_CDP_READ_TIMEOUT}" line rid ok cat rsn
  local req
  req=$(jq -cn --argjson id "$id" --argjson p "$1" '$p + {id:$id}') || { wzb_t_fail transport_failure "cannot build IPC request"; return; }
  if ! printf '%s\n' "$req" >&"$WZB_HELPER_WFD" 2>/dev/null; then
    wzb_linux_kill_helper
    wzb_t_fail transport_failure "CDP helper pipe closed (helper exited?)"; return
  fi
  if ! IFS= read -r -t "$tmo" line <&"$WZB_HELPER_RFD"; then
    wzb_linux_kill_helper
    wzb_t_fail transport_failure "CDP helper response timeout after ${tmo}s"; return
  fi
  rid=$(printf '%s' "$line" | jq -r '.id // -1' 2>/dev/null) || rid=-1
  if [ "$rid" != "$id" ]; then
    wzb_linux_kill_helper
    wzb_t_fail transport_failure "CDP helper response id mismatch (got '${rid}', want '${id}')"; return
  fi
  ok=$(printf '%s' "$line" | jq -r '.ok // false')
  if [ "$ok" != "true" ]; then
    cat=$(printf '%s' "$line" | jq -r '.category // "transport_failure"')
    rsn=$(printf '%s' "$line" | jq -r '.reason // "CDP helper error"')
    wzb_t_fail "$cat" "$rsn"; return
  fi
  WZB_CDP_RESP="$line"
  return 0
}

wzb_transport_init() {
  # 幂等：同一 CLI 内 helper 已存活即健康
  if [ -n "$WZB_HELPER_PID" ] && kill -0 "$WZB_HELPER_PID" 2>/dev/null; then
    WZB_TRANSPORT_OUT=''
    return 0
  fi
  # 精确检测真实 Google Chrome（comm 精确匹配 "chrome"；不误匹配 crashpad/ZCode 等含 chrome 字样的进程）
  if ! pgrep -x chrome >/dev/null 2>&1; then
    wzb_t_fail chrome_not_running "Google Chrome is not running; open Chrome with a logged-in chatgpt.com tab"; return
  fi
  local udd="${WZB_CDP_USER_DATA_DIR:-$HOME/.config/google-chrome}"
  if [ ! -f "$udd/DevToolsActivePort" ]; then
    wzb_t_fail remote_debugging_unavailable "DevToolsActivePort not found; enable Remote Debugging at chrome://inspect/#remote-debugging"; return
  fi
  # 启动持久 helper（exec 保证 coproc PID 即 node 进程）。
  # PID/FD 立即拷入自有普通变量——bash 在 coproc 进程退出时会 unset 掉 coproc 变量本体。
  coproc WZB_CDP { exec node "$WZB_CDP_CLIENT"; }
  WZB_HELPER_PID="$WZB_CDP_PID"
  WZB_HELPER_RFD="${WZB_CDP[0]}"
  WZB_HELPER_WFD="${WZB_CDP[1]}"
  # init = 真实健康检查（经 broker/client 真实建连 + Browser.getVersion；
  # malformed/stale/refused 在此归类）。broker 模式超时需覆盖 broker 冷启动窗口。
  if ! wzb_cdp_request '{"op":"init"}' "$((WZB_CDP_BROKER_START_TIMEOUT + WZB_CDP_CONNECT_TIMEOUT + 15))"; then
    wzb_linux_kill_helper
    return 1
  fi
  trap wzb_linux_cleanup EXIT
  WZB_TRANSPORT_OUT=''
}

# 枚举 chatgpt.com page → "TITLE<TAB>URL" 行（Target.getTargets 返回序，单进程内稳定）。
wzb_transport_list_pages() {
  wzb_cdp_request '{"op":"list"}' || return 1
  WZB_TRANSPORT_OUT=$(printf '%s' "$WZB_CDP_RESP" | jq -r '.pages[] | .title + "\t" + .url')
}

# 按 conversation id 精确查找已打开标签页 URL（复用 cli.sh 的 /c/<id> 边界解析）。
wzb_transport_find_page_url() {
  local want="$1" url cid
  wzb_transport_list_pages || return 1
  while IFS=$'\t' read -r _title url; do
    [ -n "$url" ] || continue
    cid=$(wzb_conv_id_from_url "$url")
    if [ "$cid" = "$want" ]; then
      WZB_TRANSPORT_OUT="$url"
      return 0
    fi
  done <<< "$WZB_TRANSPORT_OUT"
  WZB_TRANSPORT_OUT=''
  return 0
}

# 后台新开标签页（Target.createTarget background:true；仅允许 chatgpt.com origin）。
wzb_transport_open_page() {
  local u="$1" req
  # 精确 origin（helper 侧 isWebgptPageUrl 为最终判定；此处为早期拒绝，含显式 :443 默认端口）
  case "$u" in
    https://chatgpt.com/*|https://chatgpt.com:443/*) ;;
    *) wzb_t_fail transport_failure "open_page refused non-chatgpt.com-origin URL: ${u}"; return ;;
  esac
  req=$(jq -cn --arg url "$u" '{op:"open",url:$url}')
  wzb_cdp_request "$req" || return 1
  WZB_TRANSPORT_OUT=''
}

# 在匹配的 chatgpt.com 标签页内执行 JS；WZB_TRANSPORT_OUT="URL ||| RESULT"。
# filter 为空 = 对当前 chatgpt.com pages 依次执行固定、短超时 health probe，选择首个健康 read host；
# 非空 = 完整 URL 精确相等且不做 host fallback（helper 侧 exact ordinal equality，substring 不匹配——
# target-binding hardening，与 macOS legacy 行为不再对齐）。
# js 经 stdin 管道送达 helper（jq --arg 安全编码），不进 argv/进程列表/临时文件。
wzb_transport_eval() {
  local filter="$1" js="$2" req u v
  req=$(jq -cn --arg filter "$filter" --arg js "$js" '{op:"eval",filter:$filter,js:$js}')
  wzb_cdp_request "$req" || return 1
  u=$(printf '%s' "$WZB_CDP_RESP" | jq -r '.url // ""')
  v=$(printf '%s' "$WZB_CDP_RESP" | jq -r '.value // ""')
  WZB_TRANSPORT_OUT="${u} ||| ${v}"
}
