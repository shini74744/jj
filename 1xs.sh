#!/usr/bin/env bash
# 流量消耗/测速脚本（交互式 + 实时统计）
# 菜单 1：选择 上传/下载/同时、线程数（可自动）、地址（可默认随机）、时长（小时，空=一直）
# 菜单 2：停止全部线程；也可 Ctrl+C
# 统计：每次任务后提示“本次/线程累计/全局累计”消耗（MB）

set -Eeuo pipefail

# ====== 可编辑默认 ======
DEFAULT_THREADS=${DEFAULT_THREADS:-6}
# ======================

# 下载地址池
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

# iperf3 公共服务器（上传）
IPERF_SERVERS=(
  "iperf3.iperf.fr"
  "bouygues.iperf.fr"
  "iperf.worldstream.nl"
  "speedtest.serverius.net"
  "iperf3.cc.puv.fi"
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

have_iperf3() { command -v iperf3 >/dev/null 2>&1; }
is_running() { [[ ${#PIDS[@]} -gt 0 ]]; }

# ========== 统计相关 ==========
init_counters() {
  COUNTER_DIR="$(mktemp -d -t vpsburn.XXXXXX)"
  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE"
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE"
}
cleanup_counters() { [[ -n "$COUNTER_DIR" ]] && rm -rf "$COUNTER_DIR" 2>/dev/null || true; }

# 安全累加（有 flock 则用锁，返回累加后的新总字节数）
atomic_add() {
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

bytes_to_mb() {
  # 输出两位小数的 MB
  awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'
}

print_dl_status() {
  # $1: thread_id  $2: url  $3: bytes  $4: thread_sum_bytes
  local tid="$1" url="$2" bytes="$3" tsum="$4"
  local global_bytes
  global_bytes=$(atomic_add "$DL_TOTAL_FILE" "$bytes")
  local mb=$(bytes_to_mb "$bytes")
  local tmb=$(bytes_to_mb "$tsum")
  local gmb=$(bytes_to_mb "$global_bytes")
  echo "[DL#$tid] 目标: $url | 本次: ${mb} MB | 线程累计: ${tmb} MB | 下载总计: ${gmb} MB"
}

print_ul_status() {
  # $1: thread_id  $2: host:port  $3: bytes  $4: thread_sum_bytes
  local tid="$1" hp="$2" bytes="$3" tsum="$4"
  local global_bytes
  global_bytes=$(atomic_add "$UL_TOTAL_FILE" "$bytes")
  local mb=$(bytes_to_mb "$bytes")
  local tmb=$(bytes_to_mb "$tsum")
  local gmb=$(bytes_to_mb "$global_bytes")
  echo "[UL#$tid] 服务器: $hp | 本次: ${mb} MB | 线程累计: ${tmb} MB | 上传总计: ${gmb} MB"
}
# ============================

show_urls() {
  echo "下载地址（共 ${#URLS[@]} 个）："
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo
  echo "iperf3 上传服务器（共 ${#IPERF_SERVERS[@]} 个）："
  i=0; for s in "${IPERF_SERVERS[@]}"; do printf "  %2d) %s (5201-5209)\n" "$((++i))" "$s"; done
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

download_worker() {
  local id="$1"
  local thread_sum=0
  while true; do
    if (( END_TS > 0 )); then
      local now; now=$(date +%s)
      (( now >= END_TS )) && break
    fi
    local url="${ACTIVE_URLS[RANDOM % ${#ACTIVE_URLS[@]}]}"
    local anti_cache="$(date +%s%N)-$id-$RANDOM"
    local final="${url}?nocache=${anti_cache}"
    local bytes=0 eff="$url"

    case "$_DL_TOOL" in
      curl)
        # 输出 size_download 和 url_effective，便于统计真实跳转后地址
        local res
        if res=$(curl -sSLf --connect-timeout 15 --retry 2 -w '%{size_download} %{url_effective}' -o /dev/null "$final" 2>/dev/null); then
          bytes="${res%% *}"
          eff="${res#* }"
        else
          bytes=0
        fi
        ;;
      wget)
        # 没有 curl 时尽力读取 Content-Length（如无则未知，本次按 0 统计）
        local cl=0
        cl=$(wget --spider --server-response -O /dev/null "$final" 2>&1 | awk 'tolower($1$2)=="content-length:"{bytes=$2} END{if(bytes==""){print 0}else{print bytes}}') || true
        wget -q --timeout=15 --tries=2 -O /dev/null "$final" || true
        bytes="$cl"
        eff="$url"
        ;;
    esac

    thread_sum=$((thread_sum + bytes))
    print_dl_status "$id" "$eff" "$bytes" "$thread_sum"
  done
}

upload_worker() {
  local id="$1"
  local stint=30
  local thread_sum=0
  while true; do
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

    # 运行 iperf3 并解析 JSON 字节
    local json bytes=0
    if json=$(iperf3 -c "$host" -p "$port" -t "$t" -J 2>/dev/null); then
      # 尽量解析 end.sum_sent.bytes；若为空再尝试 sum_received.bytes
      bytes=$(echo "$json" | tr -d '\n' | sed -n 's/.*"end":[^{]*{[^}]*"sum_sent":[^{]*{[^}]*"bytes":[[:space:]]*\([0-9]\+\).*/\1/p')
      if [[ -z "${bytes:-}" ]]; then
        bytes=$(echo "$json" | tr -d '\n' | sed -n 's/.*"end":[^{]*{[^}]*"sum_received":[^{]*{[^}]*"bytes":[[:space:]]*\([0-9]\+\).*/\1/p')
      fi
      bytes=${bytes:-0}
    else
      bytes=0
      sleep 1
    fi

    thread_sum=$((thread_sum + bytes))
    print_ul_status "$id" "${host}:${port}" "$bytes" "$thread_sum"

    if (( END_TS > 0 )); then
      local now2; now2=$(date +%s)
      (( now2 >= END_TS )) && break
    fi
  done
}

start_consumption() {
  local mode="$1" dl_n="$2" ul_n="$3"
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }

  init_counters

  if [[ "$mode" != "u" ]]; then
    check_dl_tool || echo "[-] 无下载工具可用，下载统计将不可用。"
  fi
  if [[ "$mode" != "d" ]] && ! have_iperf3; then
    echo "[!] 未检测到 iperf3，无法执行上传消耗。请安装后再试（Debian/Ubuntu: apt install iperf3, CentOS: yum install iperf3）。"
    if [[ "$mode" == "u" ]]; then
      cleanup_counters
      return 1
    elif [[ "$mode" == "b" ]]; then
      echo "[*] 将仅启动下载部分。"
      mode="d"; dl_n=$((dl_n + ul_n)); ul_n=0
    fi
  fi

  echo "[*] $(human_now) 启动：模式=$mode  下载线程=$dl_n  上传线程=$ul_n"
  (( END_TS > 0 )) && echo "[*] 将在 $(date -d @"$END_TS" "+%F %T") 自动停止。"

  PIDS=()

  if [[ "$mode" != "u" ]] && (( dl_n > 0 )); then
    for ((i=1; i<=dl_n; i++)); do
      download_worker "$i" &
      PIDS+=("$!")
      sleep 0.05
    done
  fi
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

  # 打印最终汇总
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  echo "[*] 最终汇总：下载总计 $(bytes_to_mb "$dl_g") MB；上传总计 $(bytes_to_mb "$ul_g") MB"
  cleanup_counters
  echo "[+] 已全部停止。"
}

interactive_start() {
  echo "选择消耗模式： d=下载 / u=上传 / b=同时（默认 d）"
  read -rp "模式 [d/u/b]: " MODE || true
  MODE="${MODE:-d}"
  [[ "$MODE" =~ ^(d|u|b)$ ]] || MODE="d"

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
      echo "[!] 非法输入，改为一直运行。"; END_TS=0
    fi
  fi

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

trap 'echo; echo "[!] 捕获到信号，正在清理…"; stop_consumption; exit 0' INT TERM

menu() {
  while true; do
    echo
    echo "======== 流量消耗/测速 工具 ========"
    echo "1) 开始消耗（交互式：上传/下载/同时、线程、地址、时长）"
    echo "2) 停止全部线程（显示最终汇总）"
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
