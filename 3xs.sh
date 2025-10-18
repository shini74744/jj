#!/usr/bin/env bash
# 流量消耗/测速脚本（数字模式选择 + 美化菜单 + 实时统计 + 可选定时汇总）
# 菜单：
#  1) 开始消耗（交互式：上传/下载/同时、线程、地址、时长）
#  2) 停止全部线程（打印最终汇总）
#  3) 查看地址池（下载/上传）
#  4) 设置/关闭定时汇总（每 N 秒）
#  0) 退出
#
# 特性：
#  - 模式选择用数字：1=下载、2=上传、3=同时
#  - 下载：强制使用 curl 精准计量 %{size_download}；若为 0 会再发 10MB Range 兜底
#  - 上传：iperf3 -J 解析 end.sum_sent.bytes
#  - 每次任务打印：本次/线程累计/全局累计（MB），并支持“每 N 秒”自动汇总
#  - 可随时 Ctrl+C 或菜单 2 停止并清理

set -Eeuo pipefail

# ====== 可自定义默认值 ======
DEFAULT_THREADS=${DEFAULT_THREADS:-6}   # 未手动输入时的后备值（通常会按 CPU 自动估算）
SUMMARY_INTERVAL=${SUMMARY_INTERVAL:-0} # 定时汇总秒数；0=关闭
# ===========================

# 颜色/样式（若终端不支持则自动降级为无色）
init_colors() {
  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    C_RESET="$(tput sgr0)"
    C_BOLD="$(tput bold)"
    C_DIM="$(tput dim)"
    C_RED="$(tput setaf 1)"
    C_GREEN="$(tput setaf 2)"
    C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"
    C_MAGENTA="$(tput setaf 5)"
    C_CYAN="$(tput setaf 6)"
    C_WHITE="$(tput setaf 7)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""
  fi
}
init_colors

# ====== 下载地址池（可自行增减）======
URLS=(
  "https://speed.hetzner.de/1GB.bin"
  "https://speed.hetzner.de/10GB.bin"
  "https://proof.ovh.net/files/1Gb.dat"
  "https://proof.ovh.net/files/10Gb.dat"
  "http://cachefly.cachefly.net/100mb.test"
  "http://ipv4.download.thinkbroadband.com/512MB.zip"
  "http://ipv4.download.thinkbroadband.com/1GB.zip"
  "http://speedtest-sfo2.digitalocean.com/10gb.test"
  "http://speedtest-sgp1.digitalocean.com/10gb.test"
  "http://speedtest-ams2.digitalocean.com/10gb.test"
  "http://speedtest-fra1.digitalocean.com/10gb.test"
  "https://mirror.de.leaseweb.net/speedtest/100mb.bin"
  "https://mirror.nl.leaseweb.net/speedtest/100mb.bin"
  "https://mirror.us.leaseweb.net/speedtest/100mb.bin"
)

# ====== iperf3 公共服务器（可自行增减）======
IPERF_SERVERS=(
  "iperf3.iperf.fr"
  "bouygues.iperf.fr"
  "iperf.worldstream.nl"
  "speedtest.serverius.net"
  "iperf3.cc.puv.fi"
)

# ====== 运行期状态 ======
PIDS=()                   # 工作线程 PID
SUMMARY_PID=              # 汇总线程 PID
END_TS=0                  # 结束时间戳（0=一直）
DL_THREADS=0
UL_THREADS=0
ACTIVE_URLS=()
ACTIVE_SERVERS=()
MODE=""                   # "d"/"u"/"b"（内部仍用字符，外部输入为数字）
_DL_TOOL=""
COUNTER_DIR=""
DL_TOTAL_FILE=""
UL_TOTAL_FILE=""
# ======================

human_now() { date "+%F %T"; }

auto_threads() {
  local cores=1
  if command -v nproc >/dev/null 2>&1; then
    cores=$(nproc)
  elif [[ -r /proc/cpuinfo ]]; then
    cores=$(grep -c '^processor' /proc/cpuinfo || echo 1)
  fi
  local t=$(( cores * 2 ))
  (( t < 4 )) && t=4
  (( t > 32 )) && t=32
  echo "$t"
}

# ====== 工具检查 ======
check_dl_tool() {
  if command -v curl >/dev/null 2>&1; then
    _DL_TOOL="curl"
  else
    echo "${C_RED}[-] 未检测到 curl，无法精确统计下载字节。请先安装 curl。${C_RESET}"
    return 1
  fi
}
have_iperf3() { command -v iperf3 >/dev/null 2>&1; }

# ====== 统计相关 ======
init_counters() {
  COUNTER_DIR="$(mktemp -d -t vpsburn.XXXXXX)"
  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE"
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE"
}
cleanup_counters() { [[ -n "$COUNTER_DIR" ]] && rm -rf "$COUNTER_DIR" 2>/dev/null || true; }

atomic_add() {
  # $1: file  $2: add
  local file="$1" add="$2"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9<>"${file}.lock"
      flock -x 9
      local cur=0
      [[ -f "$file" ]] && cur=$(cat "$file" 2>/dev/null || echo 0)
      echo $((cur + add)) > "$file"
      cat "$file"
    )
  else
    local cur=0
    [[ -f "$file" ]] && cur=$(cat "$file" 2>/dev/null || echo 0)
    echo $((cur + add)) > "$file"
    cat "$file"
  fi
}

bytes_to_mb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }

print_dl_status() {
  local tid="$1" url="$2" bytes="$3" tsum="$4"
  local global_bytes
  global_bytes=$(atomic_add "$DL_TOTAL_FILE" "$bytes")
  echo "${C_CYAN}[DL#${tid}]${C_RESET} 目标: ${C_BLUE}${url}${C_RESET} | 本次: ${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程累计: ${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 下载总计: ${C_BOLD}$(bytes_to_mb "$global_bytes") MB${C_RESET}"
}
print_ul_status() {
  local tid="$1" hp="$2" bytes="$3" tsum="$4"
  local global_bytes
  global_bytes=$(atomic_add "$UL_TOTAL_FILE" "$bytes")
  echo "${C_MAGENTA}[UL#${tid}]${C_RESET} 服务器: ${C_BLUE}${hp}${C_RESET} | 本次: ${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程累计: ${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 上传总计: ${C_BOLD}$(bytes_to_mb "$global_bytes") MB${C_RESET}"
}

# ====== 下载测量（强制 curl）======
curl_measure() {
  # $1: URL
  # 输出: "<bytes> <url_effective>"
  curl -sS -L \
    --connect-timeout 20 --max-time 600 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    -A "Mozilla/5.0" \
    -w '%{size_download} %{url_effective}' \
    -o /dev/null "$1" 2>/dev/null || return 1
}

# ====== 辅助 ======
is_running() { [[ ${#PIDS[@]} -gt 0 ]]; }
is_summary_running() { [[ -n "${SUMMARY_PID:-}" ]] && kill -0 "$SUMMARY_PID" 2>/dev/null; }

show_urls() {
  echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo
  echo "${C_BOLD}iperf3 上传服务器（共 ${#IPERF_SERVERS[@]} 个）：${C_RESET}"
  i=0; for s in "${IPERF_SERVERS[@]}"; do printf "  %2d) %s (5201-5209)\n" "$((++i))" "$s"; done
}

show_status() {
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  echo "${C_DIM}┌───────────────────────── 状态 ─────────────────────────┐${C_RESET}"
  printf "  运行: %s   模式: %s   线程: DL=%s / UL=%s\n" \
    "$(is_running && echo "${C_GREEN}运行中${C_RESET}" || echo "${C_YELLOW}未运行${C_RESET}")" \
    "${MODE:-N/A}" \
    "${DL_THREADS:-0}" "${UL_THREADS:-0}"
  printf "  总计: 下载 %s MB / 上传 %s MB\n" \
    "$(bytes_to_mb "$dl_g")" "$(bytes_to_mb "$ul_g")"
  printf "  汇总: %s   结束: %s\n" \
    "$((SUMMARY_INTERVAL>0))" \
    "$((END_TS>0))"
  echo "${C_DIM}└────────────────────────────────────────────────────────┘${C_RESET}"
  # 上面两处 true/false 不够直观，再补充可读信息：
  echo "  汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  echo "  结束：$( ((END_TS>0)) && date -d @"$END_TS" "+%F %T" || echo "手动停止" )"
}

parse_choice_to_array() {
  local input="$1" src="$2" dst="$3"
  local -n _SRC="$src"
  local -n _DST="$dst"
  _DST=()
  [[ -z "${input// /}" ]] && { _DST=("${_SRC[@]}"); return; }
  IFS=',' read -r -a idxs <<<"$input"
  for raw in "${idxs[@]}"; do
    local n="${raw//[[:space:]]/}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n>=1 && n<=${#_SRC[@]} )) || continue
    _DST+=("${_SRC[$((n-1))]}")
  done
  [[ ${#_DST[@]} -gt 0 ]] || _DST=("${_SRC[@]}")
}

# ====== 工作线程 ======
download_worker() {
  local id="$1"
  local thread_sum=0
  while true; do
    if (( END_TS > 0 )) && (( $(date +%s) >= END_TS )); then break; fi

    local url="${ACTIVE_URLS[RANDOM % ${#ACTIVE_URLS[@]}]}"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"

    # 1) 正常完整拉取计量
    local res bytes=0 eff="$url"
    res="$(curl_measure "$final" || true)"
    if [[ -n "$res" ]]; then
      bytes="${res%% *}"
      eff="${res#* }"
    fi

    # 2) 若 bytes=0 则做 10MB Range 兜底
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
      local res2
      res2=$(curl -sS -L \
                --connect-timeout 20 --max-time 120 \
                --retry 2 --retry-all-errors \
                -A "Mozilla/5.0" \
                -H "Range: bytes=0-10485759" \
                -w '%{size_download}' \
                -o /dev/null "$final" 2>/dev/null || true)
      [[ -n "$res2" && "$res2" =~ ^[0-9]+$ ]] && bytes="$res2" || bytes=0
    fi

    thread_sum=$((thread_sum + bytes))
    print_dl_status "$id" "$eff" "$bytes" "$thread_sum"
  done
}

upload_worker() {
  local id="$1"
  local stint=30
  local thread_sum=0
  while true; do
    if (( END_TS > 0 )) && (( $(date +%s) >= END_TS )); then break; fi

    local host="${ACTIVE_SERVERS[RANDOM % ${#ACTIVE_SERVERS[@]}]}"
    local port=$((5201 + RANDOM % 9))
    local t="$stint"
    if (( END_TS > 0 )); then
      local rem=$(( END_TS - $(date +%s) ))
      (( rem <= 0 )) && break
      (( rem < t )) && t="$rem"
    fi

    local json bytes=0
    if json=$(iperf3 -c "$host" -p "$port" -t "$t" -J 2>/dev/null); then
      bytes=$(echo "$json" | tr -d '\n' | sed -n 's/.*"end":[^{]*{[^}]*"sum_sent":[^{]*{[^}]*"bytes":[[:space:]]*\([0-9]\+\).*/\1/p')
      [[ -z "${bytes:-}" ]] && bytes=$(echo "$json" | tr -d '\n' | sed -n 's/.*"end":[^{]*{[^}]*"sum_received":[^{]*{[^}]*"bytes":[[:space:]]*\([0-9]\+\).*/\1/p')
      bytes=${bytes:-0}
    else
      bytes=0
      sleep 1
    fi

    thread_sum=$((thread_sum + bytes))
    print_ul_status "$id" "${host}:${port}" "$bytes" "$thread_sum"
  done
}

# ====== 定时汇总 ======
bytes_from_file() { [[ -f "$1" ]] && cat "$1" || echo 0; }
print_summary_once() {
  local dl ul
  dl=$(bytes_from_file "$DL_TOTAL_FILE"); ul=$(bytes_from_file "$UL_TOTAL_FILE")
  echo "${C_BOLD}[Summary ${C_DIM}$(human_now)${C_RESET}${C_BOLD}]${C_RESET} 下载总计: ${C_CYAN}$(bytes_to_mb "$dl") MB${C_RESET} | 上传总计: ${C_MAGENTA}$(bytes_to_mb "$ul") MB${C_RESET}"
}
summary_worker() {
  while true; do
    sleep "$SUMMARY_INTERVAL"
    print_summary_once
  done
}
start_summary() {
  if (( SUMMARY_INTERVAL > 0 )); then
    if is_summary_running; then
      echo "${C_YELLOW}[*] 定时汇总已在运行（每 ${SUMMARY_INTERVAL}s）。${C_RESET}"
    else
      summary_worker &
      SUMMARY_PID=$!
      echo "${C_GREEN}[*] 已开启定时汇总（每 ${SUMMARY_INTERVAL}s），PID=${SUMMARY_PID}${C_RESET}"
    fi
  fi
}
stop_summary() {
  if is_summary_running; then
    kill -TERM "$SUMMARY_PID" 2>/dev/null || true
    wait "$SUMMARY_PID" 2>/dev/null || true
    SUMMARY_PID=
    echo "${C_GREEN}[+] 已停止定时汇总。${C_RESET}"
  fi
}

# ====== 启停控制 ======
start_consumption() {
  local mode="$1" dl_n="$2" ul_n="$3"
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }

  init_counters

  if [[ "$mode" != "u" ]]; then
    check_dl_tool || echo "${C_RED}[-] 无下载工具可用，下载部分将跳过。${C_RESET}"
  fi
  if [[ "$mode" != "d" ]] && ! have_iperf3; then
    echo "${C_YELLOW}[!] 未检测到 iperf3，无法执行上传消耗。请先安装（Debian/Ubuntu: apt install -y iperf3；CentOS: yum install -y iperf3）。${C_RESET}"
    if [[ "$mode" == "u" ]]; then
      cleanup_counters; return 1
    elif [[ "$mode" == "b" ]]; then
      echo "${C_YELLOW}[*] 将仅启动下载部分。${C_RESET}"
      mode="d"; dl_n=$((dl_n + ul_n)); ul_n=0
    fi
  fi

  MODE="$mode"
  PIDS=()

  echo "${C_BOLD}[*] $(human_now) 启动：模式=${MODE}  下载线程=${dl_n}  上传线程=${ul_n}${C_RESET}"
  echo "[*] 定时汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  (( END_TS > 0 )) && echo "[*] 预计结束于：$(date -d @"$END_TS" "+%F %T")"

  if [[ "$MODE" != "u" ]] && (( dl_n > 0 )); then
    for ((i=1; i<=dl_n; i++)); do
      download_worker "$i" &
      PIDS+=("$!")
      sleep 0.05
    done
  fi
  if [[ "$MODE" != "d" ]] && (( ul_n > 0 )); then
    for ((i=1; i<=ul_n; i++)); do
      upload_worker "$i" &
      PIDS+=("$!")
      sleep 0.05
    done
  fi

  start_summary
  echo "${C_GREEN}[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 或选菜单 2 可停止。${C_RESET}"
}

stop_consumption() {
  if ! is_running; then
    echo "${C_YELLOW}[*] 当前没有运行中的线程。${C_RESET}"
  else
    echo "${C_BOLD}[*] $(human_now) 正在停止全部线程…${C_RESET}"
    kill -INT "${PIDS[@]}" 2>/dev/null || true
    sleep 1
    kill -TERM "${PIDS[@]}" 2>/dev/null || true
    sleep 1
    kill -KILL "${PIDS[@]}" 2>/dev/null || true
    PIDS=()
  fi

  stop_summary

  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  echo "${C_BOLD}[*] 最终汇总：下载总计 ${C_CYAN}$(bytes_to_mb "$dl_g") MB${C_RESET}${C_BOLD}；上传总计 ${C_MAGENTA}$(bytes_to_mb "$ul_g") MB${C_RESET}"
  cleanup_counters
  echo "${C_GREEN}[+] 已全部停止。${C_RESET}"
}

# ====== 交互式启动（数字选择） ======
interactive_start() {
  echo
  echo "${C_BOLD}请选择消耗模式：${C_RESET}"
  echo "  1) 下载（仅下行）"
  echo "  2) 上传（仅上行）"
  echo "  3) 同时（上下行）"
  read -rp "模式 [1-3]（默认 1）: " mode_num || true
  [[ -z "${mode_num// /}" ]] && mode_num=1
  case "$mode_num" in
    1) MODE="d" ;;
    2) MODE="u" ;;
    3) MODE="b" ;;
    *) echo "${C_YELLOW}[!] 输入无效，使用默认：下载。${C_RESET}"; MODE="d" ;;
  esac

  read -rp "并发线程数（留空自动按 VPS 配置选择）: " t || true
  local total_threads
  if [[ -z "${t// /}" ]]; then
    total_threads=$(auto_threads)
    echo "[*] 自动选择线程数：$total_threads"
  elif [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )); then
    total_threads="$t"
  else
    echo "${C_YELLOW}[!] 非法输入，使用自动选择。${C_RESET}"
    total_threads=$(auto_threads)
  fi

  echo
  show_urls
  if [[ "$MODE" != "u" ]]; then
    read -rp "下载地址编号（逗号分隔，留空=全量随机）: " pick_dl || true
    parse_choice_to_array "${pick_dl:-}" URLS ACTIVE_URLS
  else
    ACTIVE_URLS=()
  fi
  if [[ "$MODE" != "d" ]]; then
    read -rp "上传服务器编号（逗号分隔，留空=全量随机）: " pick_ul || true
    parse_choice_to_array "${pick_ul:-}" IPERF_SERVERS ACTIVE_SERVERS
  else
    ACTIVE_SERVERS=()
  fi

  read -rp "运行多久（单位=小时，留空=一直运行）: " hours || true
  if [[ -z "${hours// /}" ]]; then
    END_TS=0; echo "[*] 将一直运行，直到手动停止。"
  else
    if [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      local secs
      secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}')
      END_TS=$(( $(date +%s) + secs ))
      echo "[*] 预计运行 ${hours} 小时，至 $(date -d @"$END_TS" "+%F %T") 停止。"
    else
      echo "${C_YELLOW}[!] 非法输入，改为一直运行。${C_RESET}"; END_TS=0
    fi
  fi

  # 线程分配
  if [[ "$MODE" == "b" ]]; then
    DL_THREADS=$(( total_threads / 2 ))
    UL_THREADS=$(( total_threads - DL_THREADS ))
  elif [[ "$MODE" == "d" ]]; then
    DL_THREADS="$total_threads"; UL_THREADS=0
  else
    DL_THREADS=0; UL_THREADS="$total_threads"
  fi

  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS"
}

# ====== 设置/开关 定时汇总 ======
configure_summary() {
  echo "当前定时汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  read -rp "输入 N（秒）：N>0 开启/修改；0 关闭；直接回车取消: " n || true
  if [[ -z "${n// /}" ]]; then
    echo "未更改。"; return
  fi
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    SUMMARY_INTERVAL="$n"
    if (( SUMMARY_INTERVAL == 0 )); then
      stop_summary
      echo "${C_GREEN}[+] 已关闭定时汇总。${C_RESET}"
    else
      echo "${C_GREEN}[+] 设置为每 ${SUMMARY_INTERVAL}s 汇总一次。${C_RESET}"
      if is_summary_running; then
        stop_summary
      fi
      if is_running; then
        start_summary
      fi
    fi
  else
    echo "${C_YELLOW}[-] 输入无效，未更改。${C_RESET}"
  fi
}

# ====== Trap / 菜单 ======
trap 'echo; echo "${C_YELLOW}[!] 捕获到信号，正在清理…${C_RESET}"; stop_consumption; exit 0' INT TERM

menu() {
  while true; do
    echo
    echo "${C_BOLD}┌────────────────────── 流量消耗/测速 工具 ──────────────────────┐${C_RESET}"
    show_status
    echo "${C_BOLD}├──────────────────────────────── 菜 单 ─────────────────────────┤${C_RESET}"
    echo "  1) 开始消耗（交互式：上传/下载/同时、线程、地址、时长）"
    echo "  2) 停止全部线程（显示最终汇总）"
    echo "  3) 查看地址池（下载/上传）"
    echo "  4) 设置/关闭定时汇总（每 N 秒）"
    echo "  0) 退出"
    echo "${C_BOLD}└────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "请选择 [0-4]: " c || true
    case "${c:-}" in
      1) interactive_start ;;
      2) stop_consumption   ;;
      3) show_urls          ;;
      4) configure_summary  ;;
      0) stop_consumption; echo "再见！"; exit 0 ;;
      *) echo "${C_YELLOW}无效选择。${C_RESET}" ;;
    esac
  done
}

menu
