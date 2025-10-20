#!/usr/bin/env bash
# 流量消耗/测速脚本（数字模式 + 彩色菜单 + 实时统计 + 定时汇总 + 仅脚本限速 + 强力清理）
# 变更：分块分离(CHUNK_MB_DL/UL)、默认仅CF上行(留空时)、智能分配线程（偶数均分/奇数自动偏向更受限的一方或默认给上传）
# 新增：菜单 2「限制模式（CPU）」：1) 恒定 50%  2) 5min@90% / 10min@50%  3) 清除；
#       在菜单 2 设置后，对菜单 1 的“开始消耗”自动生效；运行中切换也会即时生效。

# 注意：移除了 -e（出错即退出），避免在 cgroup/cpulimit 不可用时直接退回 shell
set -Euo pipefail

# =================== 新增（更平滑的 cgroup 周期） ===================
# cgroup v2 配额周期（微秒），默认 20000=20ms；范围建议 1000–100000
CGROUP_PERIOD_US=${CGROUP_PERIOD_US:-20000}
# ====================================================================

#############################
# 可自定义默认值 / 首选项
#############################
DEFAULT_THREADS=${DEFAULT_THREADS:-6}     # 留空兜底（实际会按 CPU 自动估算）
SUMMARY_INTERVAL=${SUMMARY_INTERVAL:-0}   # 定时汇总秒数；0=关闭

# 连通性与下载/上传行为
IP_VERSION=${IP_VERSION:-4}     # 4=仅IPv4, 6=仅IPv6, 0=自动
FORCE_HTTP1=${FORCE_HTTP1:-1}   # 1=强制 HTTP/1.1
ALWAYS_CHUNK=${ALWAYS_CHUNK:-1} # 1=总是按固定分块；0=先整段→失败再兜底分块

# 分块分离（MB）
CHUNK_MB_DL=${CHUNK_MB_DL:-50}  # 下载每块大小
CHUNK_MB_UL=${CHUNK_MB_UL:-10}  # 上传每块大小（默认更小以提升上传打印频率）

# 启动后是否等到第一条线程输出再回到菜单
START_WAIT_FIRST_OUTPUT=${START_WAIT_FIRST_OUTPUT:-1}  # 1=开启, 0=关闭
START_WAIT_SPINS=${START_WAIT_SPINS:-30}               # 最多等待次数；0.1s/次 → 30 ≈ 3秒

# 颜色/样式
init_colors() {
  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"; C_MAGENTA="$(tput setaf 5)"; C_CYAN="$(tput setaf 6)"; C_WHITE="$(tput setaf 7)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""
  fi
}
init_colors

# 根据 IP_VERSION / FORCE_HTTP1 生成命令选项
CURL_IP_OPT=(); HTTP_VER_OPT=()
case "$IP_VERSION" in
  4) CURL_IP_OPT+=(-4);;
  6) CURL_IP_OPT+=(-6);;
esac
(( FORCE_HTTP1 )) && HTTP_VER_OPT+=(--http1.1)

#############################
# 目标地址池（可增减）
#############################
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
  "https://store.storevideos.cdn-apple.com/v1/store.apple.com/st/1666383693478/atvloop-video-202210/streams_atvloop-video-202210/1920x1080/fileSequence3.m4s"
  "https://speed.cloudflare.com/__down?bytes=104857600"
)

# 上传地址池（HTTP 直传；默认仅 CF 上行）
UPLOAD_URLS=(
  "https://speed.cloudflare.com/__up"
  "https://httpbin.org/post"
  "https://nghttp2.org/httpbin/post"
  "https://postman-echo.com/post"
)

#############################
# 运行期状态
#############################
PIDS=()
SUMMARY_PID=
END_TS=0
DL_THREADS=0
UL_THREADS=0
ACTIVE_URLS=()
ACTIVE_UPLOAD_URLS=()
MODE=""
COUNTER_DIR=""
DL_TOTAL_FILE=""
UL_TOTAL_FILE=""
DL_LIMIT_MB=0
UL_LIMIT_MB=0

## ===== CPU 限制相关（新增） =====
LIMIT_MODE=0              # 0=无, 1=恒定50%, 2=5min@90%/10min@50%
LIMIT_METHOD=""           # "cgroup" | "cpulimit" | "none"
CGROUP_DIR=""             # cgroup v2 路径
LIMITER_PID=              # 周期限速调度器 PID（mode=2）
CPULIMIT_WATCHERS=()      # cpulimit 进程 PID 数组

#############################
# 工具函数
#############################
human_now() { date "+%F %T"; }

auto_threads() {
  local cores=1
  if command -v nproc >/dev/null 2>&1; then cores=$(nproc)
  elif [[ -r /proc/cpuinfo ]]; then cores=$(grep -c '^processor' /proc/cpuinfo || echo 1); fi
  local t=$(( cores * 2 ))
  (( t < 4 )) && t=4
  (( t > 32 )) && t=32
  echo "$t"
}

check_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "${C_RED}[-] 未检测到 curl，请先安装：apt/yum 安装 ca-certificates 与 curl。${C_RESET}"
    return 1
  fi
}

is_running() { [[ ${#PIDS[@]} -gt 0 ]]; }
is_summary_running() { [[ -n "${SUMMARY_PID:-}" ]] && kill -0 "$SUMMARY_PID" 2>/dev/null; }

show_urls() {
  echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo
  echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"
  i=0; for s in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$s"; done
}

show_status() {
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")

  local dl_thr_mb="-" ul_thr_mb="-"
  if (( DL_LIMIT_MB > 0 )) && (( DL_THREADS > 0 )); then dl_thr_mb=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}'); fi
  if (( UL_LIMIT_MB > 0 )) && (( UL_THREADS > 0 )); then ul_thr_mb=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}'); fi

  echo "${C_BOLD}┌───────────────────────── 状态 ─────────────────────────┐${C_RESET}"
  printf "  运行: %s   模式: %s   线程: DL=%s / UL=%s\n" \
    "$(is_running && echo "${C_GREEN}运行中${C_RESET}" || echo "${C_YELLOW}未运行${C_RESET}")" \
    "${MODE:-N/A}" "${DL_THREADS:-0}" "${UL_THREADS:-0}"
  printf "  总计: 下载 %s MB / 上传 %s MB\n" "$(bytes_to_mb "$dl_g")" "$(bytes_to_mb "$ul_g")"
  printf "  限速(总): DL=%s MB/s, UL=%s MB/s; 每线程≈ DL=%s MB/s, UL=%s MB/s\n" \
    "$DL_LIMIT_MB" "$UL_LIMIT_MB" "$dl_thr_mb" "$ul_thr_mb"
  printf "  汇总: %s   结束: %s\n" \
    "$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭")" \
    "$( ((END_TS>0)) && date -d @"$END_TS" "+%F %T" || echo "手动停止")"
  printf "  限制模式: %s（方法: %s）\n" \
    "$(
       case "$LIMIT_MODE" in
         0) echo "关闭" ;;
         1) echo "恒定 50%" ;;
         2) echo "5min@90% / 10min@50%" ;;
       esac
     )" \
    "$(
       case "$LIMIT_METHOD" in
         "") echo "-" ;;
         *)  echo "$LIMIT_METHOD" ;;
       esac
     )"
  echo "${C_BOLD}└────────────────────────────────────────────────────────┘${C_RESET}"
}

parse_choice_to_array() {
  local input="$1" src="$2" dst="$3"
  local -n _SRC="$src"; local -n _DST="$dst"; _DST=()
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

#############################
# 统计相关
#############################
init_counters() {
  # 优先使用 $TMPDIR，其次 /dev/shm、/var/tmp、当前目录
  local bases=()
  [[ -n "${TMPDIR:-}" ]] && bases+=("$TMPDIR")
  bases+=("/dev/shm" "/var/tmp" ".")

  COUNTER_DIR=""
  for base in "${bases[@]}"; do
    if [[ -d "$base" && -w "$base" ]]; then
      COUNTER_DIR="$(mktemp -d -p "$base" vpsburn.XXXXXX 2>/dev/null)" || true
      [[ -n "$COUNTER_DIR" ]] && break
    fi
  done

  if [[ -z "$COUNTER_DIR" ]]; then
    echo "${C_RED}[-] 无法创建临时目录：/tmp 可能已满。请设置 TMPDIR=/var/tmp 或清理磁盘后重试。${C_RESET}"
    return 1
  fi

  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE" || return 1
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE" || return 1
}
cleanup_counters() { [[ -n "$COUNTER_DIR" ]] && rm -rf "$COUNTER_DIR" 2>/dev/null || true; }

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
    local cur=0; [[ -f "$file" ]] && cur=$(cat "$file" 2>/dev/null || echo 0)
    echo $((cur + add)) > "$file"; cat "$file"
  fi
}

bytes_to_mb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }

print_dl_status() {
  local tid="$1" url="$2" bytes="$3" tsum="$4"
  local global_bytes; global_bytes=$(atomic_add "$DL_TOTAL_FILE" "$bytes")
  [[ -n "$COUNTER_DIR" && ! -f "$COUNTER_DIR/first.tick" ]] && : > "$COUNTER_DIR/first.tick"
  echo "${C_CYAN}[DL#${tid}]${C_RESET} 目标: ${C_BLUE}${url}${C_RESET} | 本次: ${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程累计: ${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 下载总计: ${C_BOLD}$(bytes_to_mb "$global_bytes") MB${C_RESET}"
}
print_ul_status() {
  local tid="$1" url="$2" bytes="$3" tsum="$4"
  local global_bytes; global_bytes=$(atomic_add "$UL_TOTAL_FILE" "$bytes")
  [[ -n "$COUNTER_DIR" && ! -f "$COUNTER_DIR/first.tick" ]] && : > "$COUNTER_DIR/first.tick"
  echo "${C_MAGENTA}[UL#${tid}]${C_RESET} 目标: ${C_BLUE}${url}${C_RESET} | 本次: ${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程累计: ${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 上传总计: ${C_BOLD}$(bytes_to_mb "$global_bytes") MB${C_RESET}"
}

#############################
# 限速计算（自动均分到线程）
#############################
calc_dl_thread_bps() {
  if (( DL_LIMIT_MB > 0 )) && (( DL_THREADS > 0 )); then
    awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1) v=1; printf "%.0f", v}'
  else echo 0; fi
}
calc_ul_thread_bps() {
  if (( UL_LIMIT_MB > 0 )) && (( UL_THREADS > 0 )); then
    awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1) v=1; printf "%.0f", v}'
  else echo 0; fi
}

#############################
# curl 封装
#############################
curl_measure_dl_range() {
  local url="$1" range_end="$2" limit_bps="${3:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  curl -sS -L \
    "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout 10 --max-time 300 \
    --retry 2 --retry-all-errors \
    -A "Mozilla/5.0" \
    -H "Range: bytes=0-${range_end}" \
    "${extra[@]}" \
    -w '%{size_download}' \
    -o /dev/null "$url" 2>/dev/null || true
}

curl_measure_full() {
  local url="$1" limit_bps="${2:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  curl -sS -L \
    "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout 10 --max-time 600 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    -A "Mozilla/5.0" \
    "${extra[@]}" \
    -w '%{size_download} %{http_code} %{url_effective}' \
    -o /dev/null "$url" 2>/dev/null || true
}

curl_measure_upload() {
  local url="$1" bytes="$2" limit_bps="${3:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  head -c "$bytes" /dev/zero | \
    curl -sS -L \
      "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
      --connect-timeout 10 --max-time 600 \
      --retry 2 --retry-all-errors \
      -A "Mozilla/5.0" \
      -H "Content-Type: application/octet-stream" \
      "${extra[@]}" \
      --data-binary @- \
      -w '%{size_upload} %{http_code}' \
      -o /dev/null \
      -X POST "$url" 2>/dev/null || true
}

#############################
# 工作线程
#############################
download_worker() {
  local id="$1"; local thread_sum=0
  while true; do
    (( END_TS > 0 )) && (( $(date +%s) >= END_TS )) && break
    local url="${ACTIVE_URLS[RANDOM % ${#ACTIVE_URLS[@]}]}"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_dl_thread_bps)
    local bytes=0
    if (( ALWAYS_CHUNK )); then
      local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
      local res2; res2=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps")
      [[ -n "$res2" && "$res2" =~ ^[0-9]+$ ]] && bytes="$res2" || bytes=0
    else
      local res code="000"
      res="$(curl_measure_full "$final" "$limit_bps")"
      if [[ -n "$res" ]]; then
        bytes="${res%% *}"; res="${res#* }"; code="${res%% *}"
      fi
      if [[ -z "$bytes" || "$bytes" == "0" || ( "$code" != "200" && "$code" != "206" ) ]]; then
        local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
        local res2; res2=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps")
        [[ -n "$res2" && "$res2" =~ ^[0-9]+$ ]] && bytes="$res2" || bytes=0
      fi
    fi
    thread_sum=$((thread_sum + bytes))
    print_dl_status "$id" "$final" "$bytes" "$thread_sum"
  done
}

upload_worker() {
  local id="$1"; local thread_sum=0
  while true; do
    (( END_TS > 0 )) && (( $(date +%s) >= END_TS )) && break
    local url="${ACTIVE_UPLOAD_URLS[RANDOM % ${#ACTIVE_UPLOAD_URLS[@]}]}"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_ul_thread_bps)
    local chunk_bytes=$(( CHUNK_MB_UL*1048576 ))
    local res; res="$(curl_measure_upload "$final" "$chunk_bytes" "$limit_bps")"
    local bytes=0 code="000"
    if [[ -n "$res" ]]; then
      bytes="${res%% *}"; code="${res##* }"
    fi
    if [[ "$code" != "200" && "$code" != "204" && "$code" != "201" && "$code" != "202" ]]; then
      bytes=0; sleep 1
    fi
    thread_sum=$((thread_sum + bytes))
    print_ul_status "$id" "$final" "$bytes" "$thread_sum"
  done
}

#############################
# 定时汇总
#############################
bytes_from_file() { [[ -f "$1" ]] && cat "$1" || echo 0; }
print_summary_once() {
  local dl ul; dl=$(bytes_from_file "$DL_TOTAL_FILE"); ul=$(bytes_from_file "$UL_TOTAL_FILE")
  echo "${C_BOLD}[Summary ${C_DIM}$(human_now)${C_RESET}${C_BOLD}]${C_RESET} 下载总计: ${C_CYAN}$(bytes_to_mb "$dl") MB${C_RESET} | 上传总计: ${C_MAGENTA}$(bytes_to_mb "$ul") MB${C_RESET}"
}
summary_worker() { while true; do sleep "$SUMMARY_INTERVAL"; print_summary_once; done; }
start_summary() {
  if (( SUMMARY_INTERVAL > 0 )); then
    if is_summary_running; then
      echo "${C_YELLOW}[*] 定时汇总已在运行（每 ${SUMMARY_INTERVAL}s）。${C_RESET}"
    else
      summary_worker & SUMMARY_PID=$!
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

#############################
# 清理辅助（强力）
#############################
kill_tree_once() {
  local sig="$1"
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    for pid in "${PIDS[@]}"; do
      pkill -"${sig}" -P "$pid" 2>/dev/null || true
      kill  -"${sig}"    "$pid" 2>/dev/null || true
    done
  fi
}

#############################
# CPU 限制实现（新增，带容错）
#############################
cores_count() {
  if command -v nproc >/dev/null 2>&1; then nproc; else echo 1; fi
}
detect_limit_method() {
  if [[ -z "$LIMIT_METHOD" ]]; then
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qw cpu /sys/fs/cgroup/cgroup.controllers && [[ -w /sys/fs/cgroup ]]; then
      LIMIT_METHOD="cgroup"
    elif command -v cpulimit >/dev/null 2>&1; then
      LIMIT_METHOD="cpulimit"
    else
      LIMIT_METHOD="none"
    fi
  fi
}
is_scheduler_running() { [[ -n "${LIMITER_PID:-}" ]] && kill -0 "$LIMITER_PID" 2>/dev/null; }
kill_scheduler() { is_scheduler_running && { kill -TERM "$LIMITER_PID" 2>/dev/null || true; wait "$LIMITER_PID" 2>/dev/null || true; LIMITER_PID=; }; }
kill_cpulimit_watchers() {
  if ((${#CPULIMIT_WATCHERS[@]})); then
    for wp in "${CPULIMIT_WATCHERS[@]}"; do kill -TERM "$wp" 2>/dev/null || true; done
    CPULIMIT_WATCHERS=()
  fi
}

# =================== 替换后的 cgroup 进入函数（确保 +cpu） ===================
cgroup_enter_self() {
  set +e
  [[ "$LIMIT_METHOD" != "cgroup" ]] && { set -e; return 0; }

  # 1) 父级打开 cpu 控制器（必要；否则 cpu.max 不会生效）
  if [[ -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
    if ! grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
      echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    fi
  fi

  # 2) 建立子组并将当前脚本进程加入（子进程会继承）
  if [[ -z "$CGROUP_DIR" ]]; then
    CGROUP_DIR="/sys/fs/cgroup/vpsburn.$$"
    mkdir -p "$CGROUP_DIR" 2>/dev/null || true
  fi
  [[ -w "$CGROUP_DIR/cgroup.procs" ]] && echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true
  set -e
}
# ============================================================================

# 按总 CPU 百分比设置限额（多核按总和计算）
# =================== 替换后的 cgroup 配额函数（使用短周期） ===================
cgroup_set_percent() {
  set +e
  local pct="$1"
  [[ "$LIMIT_METHOD" != "cgroup" ]] && { set -e; return 0; }
  [[ -z "$CGROUP_DIR" ]] && { set -e; return 0; }
  local period=${CGROUP_PERIOD_US}
  if (( pct <= 0 || pct >= 100 )); then
    echo "max" > "$CGROUP_DIR/cpu.max" 2>/dev/null || true
    set -e; return 0
  fi
  local n; n=$(cores_count)
  local quota; quota=$(awk -v P="$period" -v N="$n" -v R="$pct" 'BEGIN{printf "%.0f", P*N*R/100}')
  echo "$quota $period" > "$CGROUP_DIR/cpu.max" 2>/dev/null || true
  set -e
}
# ============================================================================

# cpulimit 附着到当前工作线程
cpulimit_apply_for_pids() {
  local pct="$1"
  kill_cpulimit_watchers
  if ! command -v cpulimit >/dev/null 2>&1; then return 0; fi
  if ((${#PIDS[@]}==0)); then return 0; fi
  for pid in "${PIDS[@]}"; do
    cpulimit -p "$pid" -l "$pct" -b >/dev/null 2>&1 &
    CPULIMIT_WATCHERS+=("$!")
  done
}

# =================== 新增：全局% → 每进程 cpulimit% 的换算 ===================
calc_cpulimit_per_proc() {
  local target_pct="$1"                # 全局目标，例如 50
  local ncores; ncores=$(cores_count)  # 逻辑核数
  local nprocs=${#PIDS[@]}            # 受控进程个数
  (( nprocs < 1 )) && nprocs=1
  # 全局预算 = 目标% * 核数；均分给每个进程；限制在 1..100
  awk -v tp="$target_pct" -v nc="$ncores" -v np="$nprocs" 'BEGIN{
    v = tp * nc / np;
    if (v < 1) v = 1; if (v > 100) v = 100;
    printf "%.0f", v
  }'
}
# ============================================================================

# 统一入口：设置瞬时限额（cpulimit: pct>=100 则直接清除监控）
limit_apply_percent() {
  set +e
  local pct="$1"
  detect_limit_method
  case "$LIMIT_METHOD" in
    cgroup)
      cgroup_set_percent "$pct"
      ;;
    cpulimit)
      if (( pct >= 100 )); then
        kill_cpulimit_watchers
      else
        # 使用换算后的每进程 -l 值，使总量更接近全局目标
        local per; per=$(calc_cpulimit_per_proc "$pct")
        cpulimit_apply_for_pids "$per"
      fi
      ;;
    *)
      echo "${C_YELLOW}[!] 本机无 cgroup v2 写权限也未安装 cpulimit，无法精确限速。${C_RESET}"
      ;;
  esac
  set -e
}
# 周期限速调度器（5min@90% → 10min@50%）
limit_scheduler() {
  while true; do
    limit_apply_percent 90; sleep 300
    limit_apply_percent 50; sleep 600
  done
}
start_limit_scheduler() { is_scheduler_running || { limit_scheduler & LIMITER_PID=$!; echo "${C_GREEN}[*] 周期限速已启用：5min@90% / 10min@50%。${C_RESET}"; }; }
stop_limit_scheduler() { kill_scheduler; }
# 模式切换
limit_set_mode() {
  set +e
  local mode="$1"
  detect_limit_method
  case "$mode" in
    0)
      LIMIT_MODE=0
      stop_limit_scheduler
      kill_cpulimit_watchers
      limit_apply_percent 100
      echo "${C_GREEN}[+] 已清除 CPU 限制。${C_RESET}"
      ;;
    1)
      LIMIT_MODE=1
      stop_limit_scheduler
      [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self
      limit_apply_percent 50
      echo "${C_GREEN}[+] 已设置恒定 50% CPU 限制。${C_RESET}"
      ;;
    2)
      LIMIT_MODE=2
      [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self
      start_limit_scheduler
      ;;
  esac
  set -e
}
ensure_limit_on_current_run() {
  (( LIMIT_MODE==0 )) && return 0
  detect_limit_method
  if [[ "$LIMIT_METHOD" == "cgroup" ]]; then
    if (( LIMIT_MODE==1 )); then limit_apply_percent 50; fi
    if (( LIMIT_MODE==2 )); then start_limit_scheduler; fi
  elif [[ "$LIMIT_METHOD" == "cpulimit" ]]; then
    if (( LIMIT_MODE==1 )); then
      local per; per=$(calc_cpulimit_per_proc 50)
      cpulimit_apply_for_pids "$per"
    fi
    if (( LIMIT_MODE==2 )); then start_limit_scheduler; fi
  fi
}

#############################
# 启停控制 & 智能分配
#############################
init_and_check() { check_curl || return 1; init_counters; }

wait_first_output() {
  (( START_WAIT_FIRST_OUTPUT )) || return 0
  for ((i=0; i<START_WAIT_SPINS; i++)); do
    [[ -f "$COUNTER_DIR/first.tick" ]] && return 0
    sleep 0.1
  done
}

smart_split_threads() {
  # 输入：$1 = total_threads；输出：设置全局 DL_THREADS / UL_THREADS
  local total="$1"
  if (( total <= 1 )); then DL_THREADS=1; UL_THREADS=0; return; fi
  if (( total % 2 == 0 )); then
    DL_THREADS=$(( total/2 )); UL_THREADS=$(( total/2 )); return
  fi
  # 奇数：优先依据限速判断“更受限的一方”，否则默认给上传
  extra_side="ul" # 默认给上传
  dl_pos=$(awk -v x="$DL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  ul_pos=$(awk -v x="$UL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  if (( dl_pos==1 || ul_pos==1 )); then
    if (( dl_pos==1 && ul_pos==0 )); then
      extra_side="dl"
    elif (( dl_pos==0 && ul_pos==1 )); then
      extra_side="ul"
    else
      cmp=$(awk -v dl="$DL_LIMIT_MB" -v ul="$UL_LIMIT_MB" 'BEGIN{if(dl<ul) print "dl"; else print "ul"}')
      extra_side="$cmp"
    fi
  fi
  if [[ "$extra_side" == "dl" ]]; then
    DL_THREADS=$(( total/2 + 1 )); UL_THREADS=$(( total - DL_THREADS ))
  else
    UL_THREADS=$(( total/2 + 1 )); DL_THREADS=$(( total - UL_THREADS ))
  fi
}

start_consumption() {
  local mode="$1" dl_n="$2" ul_n="$3"
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }
  init_and_check || { echo "${C_RED}无法启动：初始化失败（可能 /tmp 无空间或未安装 curl）。${C_RESET}"; return 1; }
  MODE="$mode"; PIDS=()

  echo "${C_BOLD}[*] $(human_now) 启动：模式=${MODE}  下载线程=${dl_n}  上传线程=${ul_n}${C_RESET}"
  echo "[*] 定时汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  (( END_TS > 0 )) && echo "[*] 预计结束于：$(date -d @"$END_TS" "+%F %T")"

  # 若已配置 CPU 限制：在启动前准备好环境（cgroup 需先入组）
  if (( LIMIT_MODE>0 )); then
    detect_limit_method
    [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self
  fi

  if [[ "$MODE" != "u" ]] && (( dl_n > 0 )); then
    for ((i=1; i<=dl_n; i++)); do download_worker "$i" & PIDS+=("$!"); sleep 0.05; done
  fi
  if [[ "$MODE" != "d" ]] && (( ul_n > 0 )); then
    for ((i=1; i<=ul_n; i++)); do upload_worker "$i" & PIDS+=("$!"); sleep 0.05; done
  fi

  start_summary
  echo "${C_GREEN}[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 或选菜单 3 可停止。${C_RESET}"
  wait_first_output

  # 子进程已就绪后，确保限速应用到当前运行（cpulimit 需要此步骤）
  ensure_limit_on_current_run
}

stop_consumption() {
  if ! is_running; then
    echo "${C_YELLOW}[*] 当前没有运行中的线程。${C_RESET}"
  else
    echo "${C_BOLD}[*] $(human_now) 正在停止全部线程…${C_RESET}"
    kill_tree_once INT;  sleep 0.5
    kill_tree_once TERM; sleep 0.5
    kill_tree_once KILL
    for pid in "${PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
      pkill -KILL -P "$pid" 2>/dev/null || true
    done
    PIDS=()
  fi
  # 停掉 cpulimit watchers（周期调度器保留，以便后续启动仍自动生效）
  kill_cpulimit_watchers
  stop_summary
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  echo "${C_BOLD}[*] 最终汇总：下载总计 ${C_CYAN}$(bytes_to_mb "$dl_g") MB${C_RESET}${C_BOLD}；上传总计 ${C_MAGENTA}$(bytes_to_mb "$ul_g") MB${C_RESET}"
  cleanup_counters
  echo "${C_GREEN}[+] 已全部停止。${C_RESET}"
}

#############################
# 交互：启动（默认=3 同时）
#############################
list_download_urls() {
  echo; echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
}
list_upload_urls() {
  echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"
  local i=0; for u in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
}

interactive_start() {
  echo; echo "${C_BOLD}请选择消耗模式：${C_RESET}"
  echo "  1) 下载（仅下行）"
  echo "  2) 上传（仅上行）"
  echo "  3) 同时（上下行）"
  read -rp "模式 [1-3]（默认 3）: " mode_num || true
  [[ -z "${mode_num// /}" ]] && mode_num=3
  case "$mode_num" in
    1) MODE="d" ;; 2) MODE="u" ;; 3) MODE="b" ;;
    *) echo "${C_YELLOW}[!] 输入无效，使用默认：同时。${C_RESET}"; MODE="b" ;;
  esac

  read -rp "并发线程数（留空自动按 VPS 配置选择）: " t || true
  local total_threads
  if [[ -z "${t// /}" ]]; then total_threads=$(auto_threads); echo "[*] 自动选择线程数：$total_threads"
  elif [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )); then total_threads="$t"
  else echo "${C_YELLOW}[!] 非法输入，使用自动选择。${C_RESET}"; total_threads=$(auto_threads); fi

  if [[ "$MODE" != "u" ]]; then
    list_download_urls
    read -rp "下载地址编号（逗号分隔，留空=全量随机）: " pick_dl || true
    parse_choice_to_array "${pick_dl:-}" URLS ACTIVE_URLS
  else
    ACTIVE_URLS=()
  fi

  if [[ "$MODE" != "d" ]]; then
    list_upload_urls
    read -rp "上传地址编号（逗号分隔，留空=默认仅 Cloudflare）: " pick_ul || true
    if [[ -z "${pick_ul// /}" ]]; then
      ACTIVE_UPLOAD_URLS=( "${UPLOAD_URLS[0]}" )
      echo "[*] 未选择编号：默认仅使用 ${UPLOAD_URLS[0]}"
    else
      parse_choice_to_array "${pick_ul:-}" UPLOAD_URLS ACTIVE_UPLOAD_URLS
    fi
  else
    ACTIVE_UPLOAD_URLS=()
  fi

  read -rp "运行多久（单位=小时，留空=一直运行）: " hours || true
  if [[ -z "${hours// /}" ]]; then
    END_TS=0; echo "[*] 将一直运行，直到手动停止。"
  elif [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    local secs; secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}')
    END_TS=$(( $(date +%s) + secs )); echo "[*] 预计运行 ${hours} 小时，至 $(date -d @"$END_TS" "+%F %T") 停止。"
  else
    echo "${C_YELLOW}[!] 非法输入，改为一直运行。${C_RESET}"; END_TS=0
  fi

  if [[ "$MODE" == "b" ]]; then
    smart_split_threads "$total_threads"
  elif [[ "$MODE" == "d" ]]; then
    DL_THREADS="$total_threads"; UL_THREADS=0
  else
    DL_THREADS=0; UL_THREADS="$total_threads"
  fi

  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS"
}

#############################
# 定时汇总设置
#############################
configure_summary() {
  echo "当前定时汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  read -rp "输入 N（秒）：N>0 开启/修改；0 关闭；直接回车取消: " n || true
  [[ -z "${n// /}" ]] && { echo "未更改。"; return; }
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    SUMMARY_INTERVAL="$n"
    if (( SUMMARY_INTERVAL == 0 )); then
      stop_summary; echo "${C_GREEN}[+] 已关闭定时汇总。${C_RESET}"
    else
      echo "${C_GREEN}[+] 设置为每 ${SUMMARY_INTERVAL}s 汇总一次。${C_RESET}"
      is_summary_running && stop_summary
      is_running && start_summary
    fi
  else
    echo "${C_YELLOW}[-] 输入无效，未更改。${C_RESET}"
  fi
}

#############################
# 限速设置（仅脚本进程）
#############################
configure_limits() {
  echo "${C_BOLD}当前限速（总速，MB/s）：DL=${DL_LIMIT_MB}，UL=${UL_LIMIT_MB}${C_RESET}"
  echo "  1) 限制上传速度（多少 M，总速，自动均分到线程）"
  echo "  2) 限制下载速度（多少 M，总速，自动均分到线程）"
  echo "  3) 同时限速（上下行都设为同样的 M）"
  echo "  4) 清除全部限速"
  read -rp "选择 [1-4]: " sub || true
  case "${sub:-}" in
    1) read -rp "输入上传总速（MB/s，0 取消限速）: " v || true
       [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已设置上传总速为 ${UL_LIMIT_MB} MB/s。${C_RESET}"
       else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    2) read -rp "输入下载总速（MB/s，0 取消限速）: " v || true
       [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已设置下载总速为 ${DL_LIMIT_MB} MB/s。${C_RESET}"
       else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    3) read -rp "输入上下行总速（MB/s，0 取消限速）: " v || true
       [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DL_LIMIT_MB="$v"; UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已将上下行总速都设为 ${v} MB/s。${C_RESET}"
       else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    4) DL_LIMIT_MB=0; UL_LIMIT_MB=0; echo "${C_GREEN}[+] 已清除全部限速。${C_RESET}";;
    *) echo "${C_YELLOW}无效选择。${C_RESET}";;
  esac

  if (( DL_LIMIT_MB > 0 )) && (( DL_THREADS > 0 )); then
    local per=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
    echo "  下载每线程≈ ${per} MB/s（curl --limit-rate）"
  fi
  if (( UL_LIMIT_MB > 0 )) && (( UL_THREADS > 0 )); then
    local per=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
    echo "  上传每线程≈ ${per} MB/s（curl --limit-rate）"
  fi

  echo "${C_DIM}（说明：限速仅作用于本脚本启动的 curl 进程，不影响系统其他进程或网卡全局配置）${C_RESET}"
}

#############################
# 限制模式菜单（新增）
#############################
configure_cpu_limit_mode() {
  echo "${C_BOLD}限制模式（CPU）：${C_RESET}当前 = $(
    case "$LIMIT_MODE" in
      0) echo "关闭" ;;
      1) echo "恒定 50%" ;;
      2) echo "周期 5min@90% / 10min@50%" ;;
    esac
  )"
  echo "  1) 限制到 50% 以下（恒定）"
  echo "  2) 5 分钟 90%，10 分钟 50%，循环"
  echo "  3) 清除限制"
  read -rp "选择 [1-3]: " lm || true
  case "${lm:-}" in
    1) limit_set_mode 1 ;;
    2) limit_set_mode 2 ;;
    3) limit_set_mode 0 ;;
    *) echo "${C_YELLOW}无效选择，未更改。${C_RESET}" ;;
  esac
  echo "${C_DIM}说明：优先使用 cgroup v2（需可写 /sys/fs/cgroup），否则回退到 cpulimit。若均不可用，将仅提示无法精确限速。${C_RESET}"
}

#############################
# Trap / 菜单
#############################
trap 'echo; echo "${C_YELLOW}[!] 捕获到信号，正在清理…${C_RESET}"; stop_consumption; exit 0' INT TERM
# 可选：在退出时尝试清理我们创建的 cgroup 目录（不影响其它功能）
trap '[[ -n "${CGROUP_DIR:-}" ]] && rmdir "$CGROUP_DIR" 2>/dev/null || true' EXIT

menu() {
  while true; do
    echo
    echo "${C_BOLD}┌────────────────────── 流量消耗/测速 工具 ──────────────────────┐${C_RESET}"
    show_status
    echo "${C_BOLD}├──────────────────────────────── 菜 单 ─────────────────────────┤${C_RESET}"
    echo "  1) 开始消耗（交互式：上传/下载/同时、线程、地址、时长）"
    echo "  2) 限制模式（CPU：50% / 5min@90%→10min@50% / 清除）"
    echo "  3) 停止全部线程（显示最终汇总）"
    echo "  4) 查看地址池（下载/上传）"
    echo "  5) 设置/关闭定时汇总（每 N 秒）"
    echo "  6) 限速设置（仅脚本生效）"
    echo "  0) 退出"
    echo "${C_BOLD}└────────────────────────────────────────────────────────────────┘${C_RESET}"
    read -rp "请选择 [0-6]: " c || true
    case "${c:-}" in
      1) interactive_start        ;;
      2) configure_cpu_limit_mode ;;
      3) stop_consumption         ;;
      4) show_urls                ;;
      5) configure_summary        ;;
      6) configure_limits         ;;
      0) stop_consumption; echo "再见！"; exit 0 ;;
      *) echo "${C_YELLOW}无效选择。${C_RESET}" ;;
    esac
  done
}

menu
