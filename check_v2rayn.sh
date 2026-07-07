#!/usr/bin/env bash
set -u

# 固化 PATH，确保从 cron/launchd 等精简环境调用时仍能找到系统命令
# (route/ifconfig/netstat/scutil/ipconfig/system_profiler 多在 /usr/sbin、/sbin)。
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"

APP_SUPPORT="${HOME}/Library/Application Support/v2rayN"
BIN_DIR="${APP_SUPPORT}/bin"
BIN_CONFIG_DIR="${APP_SUPPORT}/binConfigs"
GUI_CONFIG_DIR="${APP_SUPPORT}/guiConfigs"

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-10808}"
REQUIRE_TUN="${REQUIRE_TUN:-1}"
TUN_ADDR="${TUN_ADDR:-172.18.0.1}"
TEST_URL="${TEST_URL:-https://www.google.com/generate_204}"
IP_URL="${IP_URL:-https://api.ipify.org}"
TIMEOUT="${TIMEOUT:-15}"
CHECK_APPS="${CHECK_APPS:-Claude:/Applications/Claude.app Cursor:/Applications/Cursor.app Codex:/Applications/Codex.app}"

failures=0
warnings=0

# 仅在 stdout 连接到终端时启用颜色，重定向到文件/管道时输出纯文本，避免裸 ANSI 转义符。
if [ -t 1 ]; then
  green=$'\033[32m'
  red=$'\033[31m'
  yellow=$'\033[33m'
  bold=$'\033[1m'
  reset=$'\033[0m'
else
  green=''
  red=''
  yellow=''
  bold=''
  reset=''
fi

ok() {
  printf '%s[OK]%s %s\n' "$green" "$reset" "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"
}

fail() {
  failures=$((failures + 1))
  printf '%s[FAIL]%s %s\n' "$red" "$reset" "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# 一次性缓存全量 lsof txt 段(pid + 可执行/映射文件路径),供多个连接检查按 marker 复用,
# 避免对每个 App/CLI 各跑一次全系统 lsof 扫描。
LSOF_TXT_CACHE=""
LSOF_TXT_CACHE_LOADED=0
load_lsof_txt_cache() {
  [ "$LSOF_TXT_CACHE_LOADED" -eq 1 ] && return
  LSOF_TXT_CACHE="$(lsof -nP -d txt -Fpn 2>/dev/null)"
  LSOF_TXT_CACHE_LOADED=1
}

# 从缓存的 lsof txt 段里筛出可执行/映射路径包含 marker 的 pid。
pids_for_txt_marker() {
  marker="$1"
  load_lsof_txt_cache
  printf '%s\n' "$LSOF_TXT_CACHE" |
    awk -v marker="$marker" '
      /^p/ {pid=substr($0, 2); next}
      /^n/ && index($0, marker) > 0 && pid != "" && !seen[pid]++ {print pid; pid=""}
    '
}

require_cmd() {
  if have_cmd "$1"; then
    ok "命令可用: $1"
  else
    fail "缺少命令: $1"
  fi
}

curl_status() {
  curl -L -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null
}

curl_body() {
  curl -L -sS --max-time "$TIMEOUT" "$@" 2>/dev/null
}

get_default_interface() {
  route -n get default 2>/dev/null | awk '$1 == "interface:" {print $2; exit}'
}

get_default_gateway() {
  route -n get default 2>/dev/null | awk '$1 == "gateway:" {print $2; exit}'
}

get_interface_ipv4() {
  iface="$1"
  ipconfig getifaddr "$iface" 2>/dev/null ||
    ifconfig "$iface" 2>/dev/null | awk '$1 == "inet" {print $2; exit}'
}

get_wifi_device() {
  networksetup -listallhardwareports 2>/dev/null |
    awk '
      /^Hardware Port: Wi-Fi$/ {wifi=1; next}
      wifi && /^Device:/ {print $2; exit}
    '
}

# 从 system_profiler 解析当前连接的 Wi-Fi SSID。
# macOS Sonoma(14)起 networksetup -getairportnetwork 因隐私限制常返回空，此处作兜底。
get_wifi_network_via_profiler() {
  system_profiler SPAirPortDataType 2>/dev/null |
    awk '
      /Current Network Information:/ {in_current=1; next}
      in_current && /^[[:space:]]+[^[:space:]].*:[[:space:]]*$/ {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        sub(/:[[:space:]]*$/, "", line)
        print line
        exit
      }
    '
}

get_wifi_network() {
  iface="$1"
  [ -z "$iface" ] && return 1

  ssid="$(
    networksetup -getairportnetwork "$iface" 2>/dev/null |
      sed -E 's/^Current Wi-Fi Network: //; s/^You are not associated with an AirPort network\.$/未连接 Wi-Fi/'
  )"

  # networksetup 在新系统上可能返回空或权限提示，回退到 system_profiler。
  case "$ssid" in
    '' | *"not supported"* | *"denied"* | *Error* | *error*)
      fallback="$(get_wifi_network_via_profiler)"
      [ -n "$fallback" ] && ssid="$fallback"
      ;;
  esac

  printf '%s' "$ssid"
}

print_section() {
  printf '\n%s%s%s\n' "$bold" "$1" "$reset"
}

extract_endpoint_ip() {
  endpoint_part="$1"
  if printf '%s' "$endpoint_part" | grep -q '^\['; then
    printf '%s' "$endpoint_part" | sed -E 's/^\[([^]]+)\].*/\1/'
  else
    printf '%s' "${endpoint_part%:*}"
  fi
}

extract_local_ip() {
  endpoint="$1"
  local_part="${endpoint%%->*}"
  extract_endpoint_ip "$local_part"
}

extract_remote_ip() {
  endpoint="$1"
  remote_part="${endpoint#*->}"
  if [ "$remote_part" = "$endpoint" ]; then
    return 1
  fi
  extract_endpoint_ip "$remote_part"
}

is_loopback_ip() {
  ip="$1"
  case "$ip" in
    127.*|::1|localhost)
      return 0
      ;;
  esac
  return 1
}

is_private_ip() {
  ip="$1"
  case "$ip" in
    10.*|192.168.*|169.254.*)
      return 0
      ;;
  esac

  old_ifs="$IFS"
  IFS=.
  set -- $ip
  IFS="$old_ifs"

  # 仅在四段均为纯数字时才做数值比较，避免主机名/异常串触发 test 报错后被误判为公网
  case "${1:-}.${2:-}.${3:-}.${4:-}" in
    *[!0-9.]* | '...' )
      return 1
      ;;
  esac
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || return 1

  if [ "$1" = "172" ] && [ "$2" -ge 16 ] && [ "$2" -le 31 ]; then
    return 0
  fi

  return 1
}

route_uses_tun() {
  ip="$1"
  route -n get "$ip" 2>/dev/null |
    awk -v tun_addr="$TUN_ADDR" '
      $1 == "gateway:" && $2 == tun_addr {via_gateway=1}
      $1 == "interface:" && $2 ~ /^utun/ {via_utun=1}
      END {exit (via_gateway && via_utun) ? 0 : 1}
    '
}

expand_descendant_pids() {
  root_pids="$(printf '%s' "$1" | tr '\n' ' ')"
  [ -z "$root_pids" ] && return

  ps -axo pid=,ppid= 2>/dev/null |
    awk -v roots="$root_pids" '
      BEGIN {
        root_count=split(roots, root_list, /[[:space:]]+/)
        for (i=1; i<=root_count; i++) {
          if (root_list[i] != "") {
            wanted[root_list[i]]=1
            queue[++tail]=root_list[i]
          }
        }
      }
      {
        pid=$1
        ppid=$2
        if (pid != "" && ppid != "") {
          children[ppid]=children[ppid] " " pid
        }
      }
      END {
        for (head=1; head<=tail; head++) {
          pid=queue[head]
          if (printed[pid]++) {
            continue
          }
          print pid

          child_count=split(children[pid], child_list, /[[:space:]]+/)
          for (i=1; i<=child_count; i++) {
            child=child_list[i]
            if (child != "" && !wanted[child]++) {
              queue[++tail]=child
            }
          }
        }
      }
    '
}

check_connection_lines() {
  app_label="$1"
  conn_lines="$2"

  if [ -z "$conn_lines" ]; then
    ok "${app_label} 当前没有已建立 TCP 连接"
    return
  fi

  total=0
  explicit_proxy=0
  tun_socket=0
  tun_route=0
  local_skip=0
  bad=0

  while IFS='|' read -r command_name pid endpoint; do
    [ -z "$endpoint" ] && continue
    total=$((total + 1))

    remote_ip="$(extract_remote_ip "$endpoint" || true)"
    local_ip="$(extract_local_ip "$endpoint" || true)"

    if [ -z "$remote_ip" ] || [ -z "$local_ip" ]; then
      bad=$((bad + 1))
      fail "${app_label} 无法解析连接: ${command_name}/${pid} ${endpoint}"
      continue
    fi

    if [ "$remote_ip" = "$PROXY_HOST" ] && printf '%s' "$endpoint" | grep -q -- "->${PROXY_HOST}:${PROXY_PORT}"; then
      explicit_proxy=$((explicit_proxy + 1))
      continue
    fi

    if is_loopback_ip "$remote_ip"; then
      local_skip=$((local_skip + 1))
      continue
    fi

    if [ "$local_ip" = "$TUN_ADDR" ]; then
      tun_socket=$((tun_socket + 1))
      continue
    fi

    # 先做便宜的私网判断，命中即跳过，避免对局域网/私网连接调用 route
    if is_private_ip "$remote_ip"; then
      local_skip=$((local_skip + 1))
      continue
    fi

    # 仅对公网 remote_ip 才 fork route 查询是否走 utun
    if route_uses_tun "$remote_ip"; then
      tun_route=$((tun_route + 1))
      continue
    fi

    bad=$((bad + 1))
    fail "${app_label} 发现未走 v2rayN 的公网连接: ${command_name}/${pid} ${endpoint}"
  done <<EOF
$conn_lines
EOF

  if [ "$bad" -eq 0 ]; then
    ok "${app_label} 连接检查通过: total=${total}, local_proxy=${explicit_proxy}, tun_socket=${tun_socket}, tun_route=${tun_route}, local_skip=${local_skip}"
  else
    fail "${app_label} 连接检查失败: ${bad}/${total} 条连接未确认走 v2rayN"
  fi
}

# 给定一组 root pid，展开进程树并检查其 ESTABLISHED TCP 连接是否都走 v2rayN。
# $3 为进程未运行时的报告级别(ok 或 warn)：App 未运行算 warn，CLI 未运行算 ok。
check_process_tree_connections() {
  app_label="$1"
  root_pids="$2"
  absent_level="${3:-warn}"

  if [ -z "$root_pids" ]; then
    "$absent_level" "${app_label} 未运行，跳过连接检查"
    return
  fi

  all_pids="$(expand_descendant_pids "$root_pids")"
  pid_list="$(printf '%s\n' "$all_pids" | tr '\n' ',' | sed 's/,$//; s/^,//')"
  if [ -z "$pid_list" ]; then
    warn "${app_label} 未能展开进程树，跳过连接检查"
    return
  fi

  conn_lines="$(
    lsof -nP -a -iTCP -sTCP:ESTABLISHED -p "$pid_list" 2>/dev/null |
      awk 'NR > 1 && $8 == "TCP" {print $1 "|" $2 "|" $9}'
  )"

  check_connection_lines "$app_label" "$conn_lines"
}

check_app_connections() {
  app_label="$1"
  app_path="$2"
  # 直接从 lsof 的 txt 段找真实可执行路径，避免漏掉 ps 参数被系统改短的 Helper 进程。
  check_process_tree_connections "$app_label" "$(pids_for_txt_marker "${app_path}/Contents/")" warn
}

check_txt_marker_process_tree_connections() {
  app_label="$1"
  txt_marker="$2"
  check_process_tree_connections "$app_label" "$(pids_for_txt_marker "$txt_marker")" ok
}

# 一次性缓存全量 ESTABLISHED TCP 连接(命令名|pid|endpoint),供多个进程名兜底检查复用,
# 避免对每个进程名各跑一次全系统 lsof 扫描。
ESTABLISHED_TCP_CACHE=""
ESTABLISHED_TCP_CACHE_LOADED=0
load_established_tcp_cache() {
  [ "$ESTABLISHED_TCP_CACHE_LOADED" -eq 1 ] && return
  ESTABLISHED_TCP_CACHE="$(
    lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null |
      LC_ALL=C awk 'NR > 1 && $8 == "TCP" {print $1 "|" $2 "|" $9}'
  )"
  ESTABLISHED_TCP_CACHE_LOADED=1
}

check_process_name_connections() {
  app_label="$1"
  name_regex="$2"

  load_established_tcp_cache
  # 进程名(lsof COMMAND 列)可能含被截断的多字节/非法字节，
  # BSD awk 的 tolower() 遇到会抛 "illegal byte sequence" 并中断，
  # 用 LC_ALL=C 让 awk 按单字节处理即可规避(name_regex 均为 ASCII)。
  conn_lines="$(
    printf '%s\n' "$ESTABLISHED_TCP_CACHE" |
      LC_ALL=C awk -v name_regex="$name_regex" -F '|' '
        $1 != "" && tolower($1) ~ name_regex {print}
      '
  )"

  check_connection_lines "$app_label" "$conn_lines"
}

print_section "v2rayN 严格健康检查"
printf '检查时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '代理端口: %s:%s\n' "$PROXY_HOST" "$PROXY_PORT"
printf '要求 TUN: %s\n' "$REQUIRE_TUN"

default_iface="$(get_default_interface)"
default_gateway="$(get_default_gateway)"
default_lan_ip=""
if [ -n "$default_iface" ]; then
  default_lan_ip="$(get_interface_ipv4 "$default_iface" | tr -d '\r\n')"
fi
wifi_iface="$(get_wifi_device)"
wifi_network=""
if [ -n "$wifi_iface" ]; then
  wifi_network="$(get_wifi_network "$wifi_iface" | tr -d '\r\n')"
fi
direct_over_physical_ip=""
if [ -n "$default_iface" ]; then
  direct_over_physical_ip="$(curl_body --interface "$default_iface" "$IP_URL" | tr -d '\r\n')"
fi
early_proxy_ip="$(curl_body --proxy "http://${PROXY_HOST}:${PROXY_PORT}" "$IP_URL" | tr -d '\r\n')"

print_section "当前 Mac 网络"
printf '默认接口: %s\n' "${default_iface:-未知}"
printf '默认网关: %s\n' "${default_gateway:-未知}"
printf '局域网 IP: %s\n' "${default_lan_ip:-未知}"
if [ -n "$wifi_iface" ]; then
  printf 'Wi-Fi 接口: %s\n' "$wifi_iface"
  printf 'Wi-Fi 网络: %s\n' "${wifi_network:-未知}"
else
  printf 'Wi-Fi 接口: 未找到\n'
fi
printf '真实公网 IP: %s\n' "${direct_over_physical_ip:-获取失败}"
printf 'v2rayN 出口 IP: %s\n' "${early_proxy_ip:-获取失败}"

print_section "基础命令"
for cmd in pgrep ps lsof scutil ifconfig netstat route curl awk sed grep tr; do
  require_cmd "$cmd"
done

if [ "$failures" -gt 0 ]; then
  printf '\n%s基础命令缺失，无法继续完整检查。%s\n' "$red" "$reset"
  exit 2
fi

print_section "进程"
if pgrep -af '/Applications/v2rayN.app/Contents/MacOS/v2rayN|[v]2rayN.app' >/dev/null; then
  ok "v2rayN 主程序正在运行"
else
  fail "v2rayN 主程序未运行"
fi

if pgrep -af '[x]ray.*run -c.*config.json|bin/xray/xray' >/dev/null; then
  ok "Xray 核心正在运行"
else
  fail "Xray 核心未运行"
fi

if [ "$REQUIRE_TUN" = "1" ]; then
  if pgrep -af '[s]ing-box.*run -c.*configPre.json|bin/sing_box/sing-box' >/dev/null; then
    ok "sing-box TUN 核心正在运行"
  else
    fail "要求 TUN，但 sing-box TUN 核心未运行"
  fi
else
  if pgrep -af '[s]ing-box.*run -c.*configPre.json|bin/sing_box/sing-box' >/dev/null; then
    ok "sing-box TUN 核心正在运行"
  else
    warn "未发现 sing-box TUN 核心，当前未强制要求 TUN"
  fi
fi

print_section "监听端口"
listen_line="$(lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print}')"
if printf '%s\n' "$listen_line" | grep -q "$PROXY_HOST:$PROXY_PORT"; then
  ok "本地代理端口正在监听: $PROXY_HOST:$PROXY_PORT"
else
  fail "本地代理端口未监听: $PROXY_HOST:$PROXY_PORT"
fi

if printf '%s\n' "$listen_line" | grep -qi 'xray'; then
  ok "监听 $PROXY_PORT 的进程是 Xray"
else
  warn "监听 $PROXY_PORT 的进程未明确显示为 Xray"
fi

print_section "系统代理"
proxy_dump="$(scutil --proxy 2>/dev/null)"

for proto in HTTP HTTPS SOCKS; do
  enable_key="${proto}Enable"
  proxy_key="${proto}Proxy"
  port_key="${proto}Port"

  if printf '%s\n' "$proxy_dump" | grep -q "${enable_key} : 1"; then
    ok "${proto} 系统代理已启用"
  else
    fail "${proto} 系统代理未启用"
  fi

  if printf '%s\n' "$proxy_dump" | grep -q "${proxy_key} : ${PROXY_HOST}"; then
    ok "${proto} 系统代理地址正确: ${PROXY_HOST}"
  else
    fail "${proto} 系统代理地址不是 ${PROXY_HOST}"
  fi

  if printf '%s\n' "$proxy_dump" | grep -q "${port_key} : ${PROXY_PORT}"; then
    ok "${proto} 系统代理端口正确: ${PROXY_PORT}"
  else
    fail "${proto} 系统代理端口不是 ${PROXY_PORT}"
  fi
done

print_section "TUN 和路由"
tun_ifaces="$(ifconfig 2>/dev/null | awk -v addr="$TUN_ADDR" '
  /^[a-z0-9]+: / {iface=$1; sub(":", "", iface)}
  $1 == "inet" && $2 == addr {print iface}
')"

if [ -n "$tun_ifaces" ]; then
  ok "发现 TUN 地址 ${TUN_ADDR}: $(printf '%s' "$tun_ifaces" | tr '\n' ' ')"
else
  if [ "$REQUIRE_TUN" = "1" ]; then
    fail "未发现 TUN 地址 ${TUN_ADDR}"
  else
    warn "未发现 TUN 地址 ${TUN_ADDR}"
  fi
fi

route_dump="$(netstat -rn -f inet 2>/dev/null)"
if printf '%s\n' "$route_dump" | grep -q "$TUN_ADDR"; then
  ok "路由表包含 TUN 网关 ${TUN_ADDR}"
else
  if [ "$REQUIRE_TUN" = "1" ]; then
    fail "路由表未包含 TUN 网关 ${TUN_ADDR}"
  else
    warn "路由表未包含 TUN 网关 ${TUN_ADDR}"
  fi
fi

if printf '%s\n' "$route_dump" | awk -v addr="$TUN_ADDR" '$2 == addr && $NF ~ /^utun/ {found=1} END {exit found ? 0 : 1}'; then
  ok "路由表存在指向 utun 的透明代理路由"
else
  if [ "$REQUIRE_TUN" = "1" ]; then
    fail "未发现指向 utun 的透明代理路由"
  else
    warn "未发现指向 utun 的透明代理路由"
  fi
fi

print_section "配置校验"
if [ -x "${BIN_DIR}/xray/xray" ] && [ -f "${BIN_CONFIG_DIR}/config.json" ]; then
  if (
    cd "$BIN_CONFIG_DIR" &&
      XRAY_LOCATION_ASSET="$BIN_DIR" \
      XRAY_LOCATION_CERT="$BIN_DIR" \
      "${BIN_DIR}/xray/xray" run -test -c config.json >/dev/null 2>&1
  ); then
    ok "Xray 配置校验通过"
  else
    fail "Xray 配置校验失败"
  fi
else
  fail "找不到 Xray 或 config.json"
fi

if [ -x "${BIN_DIR}/sing_box/sing-box" ] && [ -f "${BIN_CONFIG_DIR}/configPre.json" ]; then
  if "${BIN_DIR}/sing_box/sing-box" check -c "${BIN_CONFIG_DIR}/configPre.json" >/dev/null 2>&1; then
    ok "sing-box TUN 配置校验通过"
  else
    fail "sing-box TUN 配置校验失败"
  fi
else
  if [ "$REQUIRE_TUN" = "1" ]; then
    fail "找不到 sing-box 或 configPre.json"
  else
    warn "找不到 sing-box 或 configPre.json"
  fi
fi

if [ -f "${GUI_CONFIG_DIR}/guiNConfig.json" ]; then
  if grep -q '"EnableTun"[[:space:]]*:[[:space:]]*true' "${GUI_CONFIG_DIR}/guiNConfig.json"; then
    ok "v2rayN 配置中 EnableTun=true"
  else
    if [ "$REQUIRE_TUN" = "1" ]; then
      fail "v2rayN 配置中 EnableTun 不是 true"
    else
      warn "v2rayN 配置中 EnableTun 不是 true"
    fi
  fi
else
  warn "找不到 guiNConfig.json，跳过 GUI 配置检查"
fi

print_section "网络连通性"
proxy_status="$(curl_status --proxy "http://${PROXY_HOST}:${PROXY_PORT}" "$TEST_URL")"
if [ "$proxy_status" = "204" ] || [ "$proxy_status" = "200" ]; then
  ok "显式代理访问成功: HTTP ${proxy_status}"
else
  fail "显式代理访问失败: HTTP ${proxy_status:-无响应}"
fi

direct_status="$(curl_status "$TEST_URL")"
if [ "$direct_status" = "204" ] || [ "$direct_status" = "200" ]; then
  ok "普通请求访问成功: HTTP ${direct_status}"
else
  fail "普通请求访问失败: HTTP ${direct_status:-无响应}"
fi

proxy_ip="$(curl_body --proxy "http://${PROXY_HOST}:${PROXY_PORT}" "$IP_URL" | tr -d '\r\n')"
direct_ip="$(curl_body "$IP_URL" | tr -d '\r\n')"

if [ -n "$proxy_ip" ]; then
  ok "显式代理出口 IP: ${proxy_ip}"
else
  fail "无法获取显式代理出口 IP"
fi

if [ -n "$direct_ip" ]; then
  ok "普通请求出口 IP: ${direct_ip}"
else
  fail "无法获取普通请求出口 IP"
fi

if [ -n "$proxy_ip" ] && [ -n "$direct_ip" ]; then
  if [ "$REQUIRE_TUN" = "1" ]; then
    if [ "$proxy_ip" = "$direct_ip" ]; then
      ok "普通流量出口与代理出口一致，TUN 兜底正常"
    else
      fail "普通流量出口与代理出口不一致: direct=${direct_ip}, proxy=${proxy_ip}"
    fi
  else
    if [ "$proxy_ip" = "$direct_ip" ]; then
      ok "普通流量出口与代理出口一致"
    else
      warn "普通流量出口与代理出口不一致: direct=${direct_ip}, proxy=${proxy_ip}"
    fi
  fi
fi

print_section "App 连接检查"
for app_spec in $CHECK_APPS; do
  app_label="${app_spec%%:*}"
  app_path="${app_spec#*:}"
  check_app_connections "$app_label" "$app_path"
done

print_section "CLI 连接检查"
check_txt_marker_process_tree_connections "Claude Code CLI 本地版" "${HOME}/.local/share/claude/versions/"
check_txt_marker_process_tree_connections "Claude Code CLI 桌面内置版" "${HOME}/Library/Application Support/Claude/claude-code/"

print_section "进程名兜底连接检查"
check_process_name_connections "Claude 全局进程" "claude"
check_process_name_connections "Cursor 全局进程" "cursor"
check_process_name_connections "Codex 全局进程" "codex"

print_section "最近日志"
gui_logs_dir="${APP_SUPPORT}/guiLogs"
today="$(date +%F)"
today_log="${gui_logs_dir}/${today}.txt"

# v2rayN 只在当天有事件(启动/切换/报错等)时才创建当天日志文件，
# 因此"今天没有日志"通常无害。今天缺失时回退到最近一份日志继续扫描关键错误。
log_to_scan=""
log_is_today=1
if [ -f "$today_log" ]; then
  log_to_scan="$today_log"
else
  latest_log="$(ls -1 "${gui_logs_dir}"/[0-9]*.txt 2>/dev/null | sort | tail -n 1)"
  if [ -n "$latest_log" ]; then
    log_to_scan="$latest_log"
    log_is_today=0
  fi
fi

if [ -z "$log_to_scan" ]; then
  warn "找不到任何 v2rayN 日志: ${gui_logs_dir}"
else
  critical_log_lines="$(
    tail -n 300 "$log_to_scan" |
      grep -Eai 'panic|fatal|failed to start|address already in use|permission denied|tun.*fail|sing-box.*fail|xray.*fail' || true
  )"
  if [ "$log_is_today" -eq 0 ]; then
    latest_log_date="$(basename "$log_to_scan" .txt)"
    ok "今天(${today})暂无 v2rayN 日志，改扫描最近一份: ${latest_log_date}"
  fi
  if [ -n "$critical_log_lines" ]; then
    warn "最近日志包含可疑错误，请手动查看: ${log_to_scan}"
    printf '%s\n' "$critical_log_lines" | tail -n 10
  else
    ok "最近 v2rayN 日志未发现关键错误"
  fi
fi

print_section "结果"
if [ "$failures" -eq 0 ]; then
  printf '%s服务正常。%s' "$green" "$reset"
  if [ "$warnings" -gt 0 ]; then
    printf ' 但有 %s 个警告，建议看一下上面的 WARN。\n' "$warnings"
  else
    printf '\n'
  fi
  exit 0
fi

printf '%s发现 %s 个失败项。请重启 v2rayN 后再运行本脚本检查。%s\n' "$red" "$failures" "$reset"
printf '建议操作: 退出 v2rayN -> 重新打开 v2rayN -> 确认 TUN 授权/管理员密码 -> 再执行 %s\n' "$0"
exit 1
