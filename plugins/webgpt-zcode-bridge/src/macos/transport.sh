# webgpt-zcode-bridge — macOS AppleScript transport（target-binding hardened）。
# 职责边界（ARCHITECTURE.md §5/§6）：Chrome/tab 发现、exact WebGPT origin 过滤、按 conversation id
# 精确选 tab、后台开标签页、execute javascript（exact full-URL 绑定 + post-eval URL）、transport 错误映射。
# 不包含：ChatGPT endpoint、backend schema、token、composer/verify 语义（都在 common 层）。
#
# Target-binding 语义（与 Windows Batch 4 已验证语义收敛，2026-09 Batch 4 closeout hardening）：
#   1. exact WebGPT origin：scheme=https、host=chatgpt.com、port=HTTPS 默认（缺省或 :443）；
#      拒绝 lookalike host（chatgpt.com.evil.example）、非默认端口（:444）、userinfo、错误 scheme；
#   2. eval 的非空 filter = 目标 tab 当前 URL 的**完整字符串精确相等**（AppleScript `considering case`），
#      绝不做 substring/contains 匹配；空 filter 由本层解析为第一个 exact-origin WebGPT page 的完整 URL；
#   3. post-eval URL：先执行 JS、再读取该 tab 当前 URL，返回 CURRENT_URL ||| RESULT
#      （使 common 层 wzb_assert_target_unchanged 能观察到 evaluation 期间的真实导航）。
# 全部 URL 策略集中在 bash 层；AppleScript 只做精确等值与执行，不复制策略。
#
# Batch 2A 决定（延续）：legacy 启动时自动结束 chrome-devtools 自动化 Chrome 的 workaround 不携带。

# 失败输出统一格式：stdout 单行 "category|reason"，rc 1（由 cli.sh 映射为错误对象）。
wzb_t_fail() {
  printf '%s|%s\n' "$1" "$2"
  return 1
}

# exact WebGPT origin 判定（bash 3.2，无新依赖）。
# Chrome 的 tab URL 规范化为小写 scheme/host；此处按规范形式做严格大小写敏感判定（宁可拒绝也不放宽）。
# 接受：https://chatgpt.com、https://chatgpt.com/...、https://chatgpt.com:443(/...)。
# 拒绝：其它 scheme、lookalike host（前缀/后缀域）、非默认端口、userinfo、query 中嵌入的 chatgpt URL。
wzb_mac_origin_ok() { # <url> → rc0=接受
  local u="$1" rest
  case "$u" in
    https://chatgpt.com|https://chatgpt.com:443) return 0 ;;
    https://chatgpt.com/*|https://chatgpt.com:443/*) ;;
    *) return 1 ;;
  esac
  rest="${u#https://chatgpt.com}"
  case "$rest" in
    /*|:443|:443/*) return 0 ;;
    *) return 1 ;;
  esac
}

wzb_transport_init() {
  if ! pgrep -x "Google Chrome" >/dev/null 2>&1; then
    wzb_t_fail chrome_not_running "Google Chrome is not running; open Chrome with a logged-in chatgpt.com tab"
    return
  fi
  return 0
}

# AppleScript 原始枚举所有标签页 → "TITLE<TAB>URL" 交替行（不做任何前缀过滤；origin 过滤在 bash 层）。
wzb_as_list_all_tabs() {
  osascript 2>&1 <<'EOF'
tell application "Google Chrome"
  set output to ""
  repeat with w in windows
    repeat with t in tabs of w
      try
        set output to output & (title of t as text) & linefeed & (URL of t) & linefeed
      end try
    end repeat
  end repeat
  return output
end tell
EOF
}

# 枚举 exact-origin WebGPT 标签页 → "TITLE<TAB>URL" 行（窗口/标签自然顺序，单进程内稳定）。
wzb_transport_list_pages() {
  local out rc title url
  set +e
  out=$(wzb_as_list_all_tabs)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { wzb_t_fail transport_failure "osascript list_pages failed: $out"; return; }
  while IFS= read -r title; do
    IFS= read -r url || break
    if wzb_mac_origin_ok "$url"; then
      printf '%s\t%s\n' "$title" "$url"
    fi
  done <<< "$out"
}

# 按 conversation id 精确查找已打开标签页 URL（复用 cli.sh 的 /c/<id> 边界解析，非裸 substring）。
wzb_transport_find_page_url() {
  local want="$1" out rc title url cid
  set +e
  out=$(wzb_transport_list_pages)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  while IFS=$'\t' read -r title url; do
    [ -n "$url" ] || continue
    cid=$(wzb_conv_id_from_url "$url")
    if [ "$cid" = "$want" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  done <<< "$out"
  printf ''
  return 0
}

# 后台新开标签页（不激活前台，不触碰用户现有标签页）。仅接受 exact-origin WebGPT URL。
wzb_transport_open_page() {
  local u="$1" out rc
  wzb_mac_origin_ok "$u" || { wzb_t_fail transport_failure "open_page refused non-WebGPT URL: $u"; return; }
  set +e
  out=$(osascript - "$u" 2>&1 <<'EOF'
on run argv
  set u to item 1 of argv
  tell application "Google Chrome"
    if (count of windows) = 0 then
      make new window
      set URL of active tab of front window to u
    else
      tell front window
        make new tab with properties {URL:u}
      end tell
    end if
  end tell
  return "OPENED"
end run
EOF
) rc=$?
  set -e
  [ "$rc" -eq 0 ] || { wzb_t_fail transport_failure "osascript open_page failed: $out"; return; }
  return 0
}

# 在目标 tab 内执行 JS；stdout "POSTEVAL_URL ||| RESULT"。
# 非空 filter：与 tab 当前 URL 完整字符串精确相等（considering case），不做 substring 匹配；
# 空 filter：由本层先解析第一个 exact-origin WebGPT page 的完整 URL（stable first），再同路径精确绑定。
# AppleScript 内先执行 JS、保存结果，再读取该 tab 当前 URL——返回的是 post-evaluation URL。
wzb_transport_eval() {
  local filter="$1" js="$2" target out rc first
  target="$filter"
  if [ -z "$target" ]; then
    set +e
    first=$(wzb_transport_list_pages)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { wzb_t_fail transport_failure "list_pages failed while resolving read host: $first"; return; }
    target=$(printf '%s\n' "$first" | head -n 1 | cut -f2-)
    [ -n "$target" ] || { wzb_t_fail no_webgpt_page "no exact-origin WebGPT page open"; return; }
  fi
  wzb_mac_origin_ok "$target" || { wzb_t_fail transport_failure "eval target is not an exact WebGPT origin URL: ${target}"; return; }
  set +e
  out=$(osascript - "$target" "$js" 2>&1 <<'EOF'
on run argv
  set f to item 1 of argv
  set js to item 2 of argv
  tell application "Google Chrome"
    repeat with w in windows
      repeat with t in tabs of w
        considering case
          if (URL of t) = f then
            set jsResult to (execute t javascript js)
            set postURL to (URL of t)
            return postURL & " ||| " & jsResult
          end if
        end considering
      end repeat
    end repeat
  end tell
  return "ERR_NO_CHATGPT_TAB"
end run
EOF
) rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"turned off"*|*"AppleScript"*)
        wzb_t_fail transport_failure "Chrome JavaScript-from-Apple-Events is off; enable View → Developer → Allow JavaScript from Apple Events. detail: $out"
        return ;;
      *)
        wzb_t_fail transport_failure "osascript eval failed: $out"
        return ;;
    esac
  fi
  case "$out" in
    ERR_NO_CHATGPT_TAB*)
      wzb_t_fail no_webgpt_page "no open tab has exact URL '${target}'"
      return ;;
  esac
  printf '%s\n' "$out"
}
