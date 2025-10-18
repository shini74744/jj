#!/usr/bin/env bash
# 流量消耗/测速脚本（交互式）
# 功能：
#  - 菜单 1 交互选择：上传/下载/同时、线程数、地址、运行时长（小时）
#  - 菜单 2 停止全部线程（或 Ctrl+C）
#  - 下载用 curl/wget；上传用 iperf3（公共 iperf3 服务器，自动轮询端口 5201-5209）
#  - 合理使用，避免对单一站过高并发或长期压测

set -Eeuo pipefail

# ====== 可编辑默认 ======
DEFAULT_THREADS=${DEFAULT_THREADS:-6}
# ======================

# 下载地址池（可自行增减）
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

# 常见 iperf3 公共服务器（可自行增减；可用性由第三方维护，若不可用会自动换下一个）
IPERF_SERVERS=(
  "iperf3.iperf.fr"        # FR (巴黎)
  "bouygues.iperf.fr"      # FR (巴黎)
  "iperf.worldstream.nl"   # NL
  "speedtest.serverius.net" # NL
  "iperf3.cc.puv.fi"       # FI
)

# ====== 运行期状态 ======
PIDS=()
END_TS=0
DL_THREADS=0
UL_THREADS=0
ACTIVE_URLS=()
ACTIVE_SERVERS=()
MODE=""  # d/u/b
_DL_TOOL=""
# ======================

human_now() { date "+%F %T"; }

auto_threads() {
  local cores=1
  if command -v nproc >/dev/null 2>&1; then
    cores=$(nproc)
  elif [[ -r /proc/cpuinfo ]]; then
    cores=$(grep -c '^processor' /proc/cpuinfo || echo 1)
  fi
  # 简单启发式：线程 = cores * 2，夹在 [4, 32]
  local t=$(( cores * 2 ))
  (( t < 4 )) && t=4
  (( t > 32 )) && t=32
  echo "$t"
}

check_dl_tool() {
  if command -v curl >/dev/null 2>&1; then
    _DL_TOOL="curl"
  elif command -v wget >/dev/null 2>&1; then
    _DL_TOOL="wget"
  else
    echo "[-] 需要安装 curl 或 wget 才能进行下载消耗。"
    return 1
  fi
}

have_iperf3() {
  command -v iperf3 >/dev/null 2>&1
}

is_running() { [[ ${#PIDS[@]} -gt 0 ]]; }

show_urls() {
  echo "下载地址（共 ${#URLS[@]} 个）："
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo
  echo "iperf3 上传服务器（共 ${#IPERF_SERVERS[@]} 个）："
  i=0; for s in "${IPERF_SERVERS[@]}"; do printf "  %2d) %s (5201-5209)\n" "$((++i))" "$s"; done
}

parse_choice_to_array() {
  # $1: 输入 (如 "1,3,5"), $2: 源数组名, $3: 目标数组名
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
  # 若用户给了非法输入导致为空，则回退为全量
  [[ ${#_DST[@]} -gt 0 ]] || _DST=("${_SRC[@]}")
}

download_worker() {
  local id="$1"
  while true; do
    # 时长控制
    if (( END_TS > 0 )); then
      local now; now=$(date +%s)
      (( now >= END_TS )) && break
    fi
    local url="${ACTIVE_URLS[RANDOM % ${#ACTIVE_URLS[@]}]}"
    local anti_cache="$(date +%s%N)-$id-$RANDOM"
    case "$_DL_TOOL" in
      curl)
        curl -sSLf --connect-timeout 15 --retry 2 --output /dev/null \
          "${url}?nocache=${anti_cache}" || true
        ;;
      wget)
        wget -q --timeout=15 --tries=2 -O /dev/null \
          "${url}?nocache=${anti_cache}" || true
        ;;
    esac
  done
}

upload_worker() {
  local id="$1"
  local stint=30   # 每次 iperf3 持续秒数；循环执行直至时长结束
  while true; do
    # 选择服务器与端口
    local host="${ACTIVE_SERVERS[RANDOM % ${#ACTIVE_SERVERS[@]}]}"
    local port=$((5201 + RANDOM % 9))
    local t="$stint"
    if (( END_TS > 0 )); then
      local now rem
      now=$(date +%s)
      rem=$(( END_TS - now ))
      (( rem <= 0 )) && break
      (( rem < t )) && t="$rem"
    fi
    # 客户端 -> 服务器 即上传；-t 指定秒数；失败就换下一个
    iperf3 -c "$host" -p "$port" -t "$t" -J >/dev/null 2>&1 || sleep 1
    # 循环到下一轮
    if (( END_TS > 0 )); then
      local now2; now2=$(date +%s)
      (( now2 >= END_TS )) && break
    fi
  done
}

start_consumption() {
  local mode="$1" dl_n="$2" ul_n="$3"
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }
  PIDS=()

  if [[ "$mode" != "u" ]]; then
    check_dl_tool || { echo "[-] 无下载工具可用，已跳过下载部分。"; }
  fi

  if [[ "$mode" != "d" ]] && ! have_iperf3; then
    echo "[!] 未检测到 iperf3，无法执行上传消耗。请安装后再试（Debian/Ubuntu: apt install iperf3, CentOS: yum install iperf3）。"
    if [[ "$mode" == "u" ]]; then
      return 1
    elif [[ "$mode" == "b" ]]; then
      echo "[*] 将仅启动下载部分。"
      mode="d"; dl_n=$((dl_n + ul_n)); ul_n=0
    fi
  fi

  echo "[*] $(human_now) 启动：模式=$mode  下载线程=$dl_n  上传线程=$ul_n"
  (( END_TS > 0 )) && echo "[*] 将在 $(date -d @"$END_TS" "+%F %T") 自动停止。"

  # 启动下载线程
  if [[ "$mode" != "u" ]] && (( dl_n > 0 )); then
    for ((i=1; i<=dl_n; i++)); do
      download_worker "$i" &
      PIDS+=("$!")
      sleep 0.05
    done
  fi

  # 启动上传线程
  if [[ "$mode" != "d" ]] && (( ul_n > 0 )); then
    for ((i=1; i<=ul_n; i++)); do
      upload_worker "$i" &
      PIDS+=("$!")
      sleep 0.05
    done
  fi

  echo "[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 或选菜单 2 可停止。"
}

stop_consumption() {
  if ! is_running; then
    echo "[*] 当前没有运行中的线程。"
    return
  fi
  echo "[*] $(human_now) 正在停止全部线程…"
  kill -INT "${PIDS[@]}" 2>/dev/null || true
  sleep 1
  kill -TERM "${PIDS[@]}" 2>/dev/null || true
  sleep 1
  kill -KILL "${PIDS[@]}" 2>/dev/null || true
  PIDS=()
  echo "[+] 已全部停止。"
}

interactive_start() {
  # 1) 模式
  echo "选择消耗模式： d=下载 / u=上传 / b=同时（默认 d）"
  read -rp "模式 [d/u/b]: " MODE || true
  MODE="${MODE:-d}"
  [[ "$MODE" =~ ^(d|u|b)$ ]] || MODE="d"

  # 2) 线程数（总数；若选择同时，会自动平分）
  read -rp "并发线程数（留空自动按 VPS 配置选择）: " t || true
  local total_threads
  if [[ -z "${t// /}" ]]; then
    total_threads=$(auto_threads)
    echo "[*] 自动选择线程数：$total_threads"
  elif [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )); then
    total_threads="$t"
  else
    echo "[!] 非法输入，使用自动选择。"
    total_threads=$(auto_threads)
  fi

  # 3) 地址选择
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

  # 4) 运行时长（小时）
  read -rp "运行多久（单位=小时，留空=一直运行）: " hours || true
  if [[ -z "${hours// /}" ]]; then
    END_TS=0
    echo "[*] 将一直运行，直到手动停止。"
  else
    # 支持小数小时，如 0.5
    if [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      local secs
      # bash 不支持浮点，借助 awk 计算
      secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}')
      END_TS=$(( $(date +%s) + secs ))
      echo "[*] 预计运行 ${hours} 小时，至 $(date -d @"$END_TS" "+%F %T") 停止。"
    else
      echo "[!] 非法输入，改为一直运行。"
      END_TS=0
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

  # 开始
  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS"
}

trap 'echo; echo "[!] 捕获到信号，正在清理…"; stop_consumption; exit 0' INT TERM

menu() {
  while true; do
    echo
    echo "======== 流量消耗/测速 工具 ========"
    echo "1) 开始消耗（交互式选择：上传/下载/同时、线程、地址、时长）"
    echo "2) 停止全部线程"
    echo "3) 查看当前地址池"
    echo "0) 退出"
    read -rp "请选择 [0-3]: " c || true
    case "${c:-}" in
      1) interactive_start ;;
      2) stop_consumption   ;;
      3) show_urls          ;;
      0) stop_consumption; echo "再见！"; exit 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

menu
