#!/usr/bin/env bash
# 流量消耗/测速脚本（分块/仅脚本限速/CPU行为模拟/熔断与看门狗/定时汇总/强力清理/美化UI）
# - 菜单去美化（主菜单使用纯文本，避免乱码）
# - 行输出：固定列宽（本次/累计/速率/URL 全量显示且数字上色）
# - 停滞/超时杀手、端点熔断、线程看门狗、IPv4/IPv6 自动探测
# - Ctrl+C、SSH断开(SIGHUP)、正常 EXIT 都会完整清理

set -Euo pipefail

# --- 终端/信号补丁：保证能收到 ^C，且即使在管道/重定向下也读自真实 TTY ---
if [[ -e /dev/tty ]]; then exec 0</dev/tty; fi
stty isig -echoctl 2>/dev/null || true

# ====== 统一退出/信号处理（防重入） ======
__SIG_HANDLED=0
__on_exit_or_signal() {
  (( __SIG_HANDLED )) && exit 0
  __SIG_HANDLED=1
  echo "[!] 捕获到信号，正在清理…"
  stop_consumption 1
  exit 0
}
# 捕获：Ctrl+C(INT)、终端关闭(HUP)、常见终止(TERM/QUIT)，以及任何 EXIT
trap __on_exit_or_signal INT TERM HUP QUIT
trap __on_exit_or_signal EXIT

# =================== cgroup 周期（更平滑） ===================
CGROUP_PERIOD_US=${CGROUP_PERIOD_US:-20000}  # 微秒，建议 1000–100000
# ============================================================

#############################
# 可自定义默认值 / 首选项
#############################
DEFAULT_THREADS=${DEFAULT_THREADS:-6}
SUMMARY_INTERVAL=${SUMMARY_INTERVAL:-0}    # 0=关闭

# 连通性与下载/上传行为
IP_VERSION=${IP_VERSION:-4}     # 4=仅IPv4, 6=仅IPv6, 0=自动探测
FORCE_HTTP1=${FORCE_HTTP1:-1}   # 1=HTTP/1.1

# 分块策略
ALWAYS_CHUNK=${ALWAYS_CHUNK:-1} # 1=总是 Range 分块；0=先整段→失败再分块（整段带 128MB 保险）
CHUNK_MB_DL=${CHUNK_MB_DL:-50}
CHUNK_MB_UL=${CHUNK_MB_UL:-10}

# 首条输出等待
START_WAIT_FIRST_OUTPUT=${START_WAIT_FIRST_OUTPUT:-1}
START_WAIT_SPINS=${START_WAIT_SPINS:-30}   # 0.1s×N

# curl 停滞/超时“看门狗”
CURL_CONNECT_TIMEOUT=${CURL_CONNECT_TIMEOUT:-5}
CURL_MAX_TIME=${CURL_MAX_TIME:-60}
CURL_SPEED_TIME=${CURL_SPEED_TIME:-8}
CURL_SPEED_LIMIT=${CURL_SPEED_LIMIT:-131072}  # 128 KB/s 判停滞

# 线程级看门狗（心跳文件超时则重启该线程）
WATCHDOG_ENABLE=${WATCHDOG_ENABLE:-1}
WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL:-5}
WATCHDOG_STALL=${WATCHDOG_STALL:-20}
WATCHDOG_MAX_RESTARTS=${WATCHDOG_MAX_RESTARTS:-0} # 0=不限制

# 抑制 CPU 限制警告（清理阶段置 1）
SUPPRESS_CPUWARN=0

# 颜色/样式
init_colors() {
  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"; C_MAGENTA="$(tput setaf 5)"; C_CYAN="$(tput setaf 6)"; C_WHITE="$(tput setaf 7)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""
  fi
}
init_colors

# 根据 IP_VERSION / FORCE_HTTP1 生成命令选项
CURL_IP_OPT=(); HTTP_VER_OPT=()
case "$IP_VERSION" in
  4) CURL_IP_OPT+=(-4);;
  6) CURL_IP_OPT+=(-6);;
  0) : ;;
esac
(( FORCE_HTTP1 )) && HTTP_VER_OPT+=(--http1.1)

# IPv4/IPv6 自动探测（仅当 IP_VERSION=0）
auto_pick_ip_version() {
  [[ "${IP_VERSION:-0}" != "0" ]] && return
  if curl -6 -I -s --connect-timeout 2 https://www.cloudflare.com >/dev/null 2>&1; then
    CURL_IP_OPT=(-6)
  else
    CURL_IP_OPT=(-4)
  fi
}
auto_pick_ip_version

#############################
# 目标地址池（按你指定）
#############################
URLS=(
  "https://nbg1-speed.hetzner.com/100MB.bin"
  "https://nbg1-speed.hetzner.com/1GB.bin"
  "https://fsn1-speed.hetzner.com/100MB.bin"
  "https://fsn1-speed.hetzner.com/1GB.bin"
  "https://hel1-speed.hetzner.com/100MB.bin"
  "https://hel1-speed.hetzner.com/1GB.bin"
  "https://ash-speed.hetzner.com/100MB.bin"
  "https://ash-speed.hetzner.com/1GB.bin"
  "https://hil-speed.hetzner.com/100MB.bin"
  "https://hil-speed.hetzner.com/1GB.bin"
  "https://sin-speed.hetzner.com/100MB.bin"
  "https://sin-speed.hetzner.com/1GB.bin"
  "https://speed.cloudflare.com/__down?bytes=104857600"
  "https://speed.cloudflare.com/__down?during=download&bytes=1073741824"
  "https://store.storevideos.cdn-apple.com/v1/store.apple.com/st/1666383693478/atvloop-video-202210/streams_atvloop-video-202210/1920x1080/fileSequence3.m4s"
)

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

declare -A DL_PIDS UL_PIDS
declare -A DL_HB UL_HB
declare -A DL_RESTARTS UL_RESTARTS

## ===== CPU 限制相关 =====
LIMIT_MODE=0              # 0=无, 1=恒定50%, 2=模拟正常使用
LIMIT_METHOD=""           # "cgroup" | "cpulimit" | "none"
CGROUP_DIR=""             # cgroup v2 路径
LIMITER_PID=              # 调度器 PID
CPULIMIT_WATCHERS=()      # cpulimit PID
NONE_WARNED=0

WATCHDOG_PID=

#############################
# 熔断/冷却
#############################
declare -A URL_FAILS URL_COOLDOWN
now_epoch() { date +%s; }
url_on_cooldown() { local u="$1" now; now=$(now_epoch); local until="${URL_COOLDOWN[$u]:-0}"; (( now < until )); }
mark_url_fail() {
  local u="$1" fails=$(( ${URL_FAILS[$u]:-0} + 1 ))
  URL_FAILS[$u]=$fails
  local cd=$(( 5 * fails ))
  URL_COOLDOWN[$u]=$(( $(now_epoch) + cd ))
}
mark_url_ok() { local u="$1"; URL_FAILS[$u]=0; URL_COOLDOWN[$u]=0; }

pick_active_dl_url() {
  local candidates=() u
  for u in "${ACTIVE_URLS[@]}"; do url_on_cooldown "$u" || candidates+=("$u"); done
  ((${#candidates[@]}==0)) && candidates=("${ACTIVE_URLS[@]}")
  echo "${candidates[RANDOM % ${#candidates[@]}]}"
}
pick_active_ul_url() {
  local candidates=() u
  for u in "${ACTIVE_UPLOAD_URLS[@]}"; do url_on_cooldown "$u" || candidates+=("$u"); done
  ((${#candidates[@]}==0)) && candidates=("${ACTIVE_UPLOAD_URLS[@]}")
  echo "${candidates[RANDOM % ${#candidates[@]}]}"
}

#############################
# UI 辅助
#############################
term_cols() { command -v tput >/dev/null 2>&1 && tput cols || echo 80; }
repeat_char() { local n="$1" ch="${2:-─}"; printf "%*s" "$n" "" | tr ' ' "$ch"; }

#############################
# 工具函数
#############################
human_now() { date "+%F %T"; }
date_human_ts() {
  if date -d @0 +%F >/dev/null 2>&1; then date -d @"$1" "+%F %T"
  elif date -r 0 +%F >/dev/null 2>&1; then date -r "$1" "+%F %T"
  else echo "$1"; fi
}
auto_threads() {
  local cores=1
  if command -v nproc >/dev/null 2>&1; then cores=$(nproc)
  elif [[ -r /proc/cpuinfo ]]; then cores=$(grep -c '^processor' /proc/cpuinfo || echo 1); fi
  local t=$(( cores * 2 )); (( t < 4 )) && t=4; (( t > 32 )) && t=32; echo "$t"
}
check_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "${C_RED}[-] 未检测到 curl，请先安装 ca-certificates 与 curl。${C_RESET}"; return 1
  fi
}
is_running() { [[ ${#PIDS[@]} -gt 0 ]]; }
is_summary_running() { [[ -n "${SUMMARY_PID:-}" ]] && kill -0 "$SUMMARY_PID" 2>/dev/null; }

show_urls() {
  echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"
  local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"
  i=0; for s in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$s"; done
}

#############################
# 统计相关
#############################
init_counters() {
  local bases=(); [[ -n "${TMPDIR:-}" ]] && bases+=("$TMPDIR"); bases+=("/dev/shm" "/var/tmp" ".")
  COUNTER_DIR=""
  for base in "${bases[@]}"; do
    if [[ -d "$base" && -w "$base" ]]; then
      COUNTER_DIR="$(mktemp -d -p "$base" vpsburn.XXXXXX 2>/dev/null)" || true
      [[ -n "$COUNTER_DIR" ]] && break
    fi
  done
  if [[ -z "$COUNTER_DIR" ]]; then
    echo "${C_RED}[-] 无法创建临时目录：/tmp 可能已满。请设 TMPDIR=/var/tmp 或清理磁盘。${C_RESET}"; return 1
  fi
  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE" || return 1
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE" || return 1
}
cleanup_counters() { [[ -n "$COUNTER_DIR" ]] && rm -rf "$COUNTER_DIR" 2>/dev/null || true; }

atomic_add() {
  local file="$1" add="$2"
  if command -v flock >/dev/null 2>&1; then
    ( exec 9<>"${file}.lock"; flock -x 9; local cur=0; [[ -f "$file" ]] && cur=$(cat "$file" 2>/dev/null || echo 0); echo $((cur + add)) > "$file"; cat "$file" )
  else
    local cur=0; [[ -f "$file" ]] && cur=$(cat "$file" 2>/dev/null || echo 0); echo $((cur + add)) > "$file"; cat "$file"
  fi
}
bytes_to_mb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }
fmt_mb()   { awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }
fmt_rate() { local bytes="$1" sec="$2"; awk -v b="$bytes" -v s="$sec" 'BEGIN{ if(s<=0.000001){print "—"} else printf "%.2f", (b/1048576)/s }'; }

#############################
# UI：状态栏（ASCII） + 主菜单（ASCII）
#############################
show_status() {
  local cols; cols=$(term_cols); (( cols<70 )) && cols=70

  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")

  local dl_thr="-" ul_thr="-"
  (( DL_LIMIT_MB>0 && DL_THREADS>0 )) && dl_thr=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
  (( UL_LIMIT_MB>0 && UL_THREADS>0 )) && ul_thr=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}')

  local line; line="$(repeat_char "$cols" "-")"
  local summary_text; if (( SUMMARY_INTERVAL>0 )); then summary_text="每 ${SUMMARY_INTERVAL}s"; else summary_text="关闭"; fi
  local end_text; if (( END_TS>0 )); then end_text="$(date_human_ts "$END_TS")"; else end_text="手动停止"; fi
  local cpu_text; case "$LIMIT_MODE" in 0) cpu_text="关闭";; 1) cpu_text="恒定50%";; 2) cpu_text="模拟正常使用";; esac

  echo "${C_BOLD}=== 流量消耗/测速 工具 ===${C_RESET}"
  echo "$line"
  printf "运行状态 : %s\n" "$( is_running && echo '运行中' || echo '未运行' )"
  printf "当前模式 : %s\n" "${MODE:-N/A}"
  printf "线程数   : DL=%s / UL=%s\n" "${DL_THREADS:-0}" "${UL_THREADS:-0}"
  printf "定时汇总 : %s\n" "$summary_text"
  printf "下载总计 : %s MB\n" "$(bytes_to_mb "$dl_g")"
  printf "上传总计 : %s MB\n" "$(bytes_to_mb "$ul_g")"
  printf "限速(总) : DL=%s / UL=%s MB/s\n" "${DL_LIMIT_MB}" "${UL_LIMIT_MB}"
  printf "每线程≈  : DL=%s / UL=%s MB/s\n" "${dl_thr}" "${ul_thr}"
  printf "结束时间 : %s\n" "$end_text"
  printf "CPU限制  : %s (方法: %s)\n" "$cpu_text" "${LIMIT_METHOD:-"-"}"
  echo "$line"

  echo "菜单："
  echo "  1) 开始（交互式：上下行/线程/地址/时长）"
  echo "  2) 限制模式：1=恒定50% / 2=模拟 / 3=清除"
  echo "  3) 停止全部线程（显示最终汇总）"
  echo "  4) 地址池（下载/上传）"
  echo "  5) 定时汇总（每 N 秒）"
  echo "  6) 限速设置（仅脚本生效）"
  echo "  0) 退出"
  echo "$line"
}

#############################
# 限速计算（自动均分到线程）
#############################
calc_dl_thread_bps() {
  if (( DL_LIMIT_MB > 0 && DL_THREADS > 0 )); then awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1) v=1; printf "%.0f", v}'; else echo 0; fi
}
calc_ul_thread_bps() {
  if (( UL_LIMIT_MB > 0 && UL_THREADS > 0 )); then awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1) v=1; printf "%.0f", v}'; else echo 0; fi
}

#############################
# curl 封装
#############################
curl_measure_dl_range() {
  local url="$1" range_end="$2" limit_bps="${3:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  curl -sS -L \
    "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry 2 --retry-all-errors \
    --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
    -A "Mozilla/5.0" -H "Range: bytes=0-${range_end}" \
    "${extra[@]}" \
    -w '%{size_download} %{time_total}' \
    -o /dev/null "$url" 2>/dev/null || true
}
curl_measure_full() {
  local url="$1" limit_bps="${2:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  local max_bytes=$((128*1024*1024))
  curl -sS -L \
    "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
    --max-filesize "$max_bytes" \
    -A "Mozilla/5.0" "${extra[@]}" \
    -w '%{size_download} %{time_total} %{http_code} %{url_effective}' \
    -o /dev/null "$url" 2>/dev/null || true
}
curl_measure_upload() {
  local url="$1" bytes="$2" limit_bps="${3:-0}"
  local extra=(); (( limit_bps > 0 )) && extra+=(--limit-rate "$limit_bps")
  head -c "$bytes" /dev/zero | \
    curl -sS -L \
      "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      --retry 2 --retry-all-errors \
      --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
      -A "Mozilla/5.0" -H "Content-Type: application/octet-stream" \
      "${extra[@]}" \
      --data-binary @- \
      -w '%{size_upload} %{time_total} %{http_code}' \
      -o /dev/null -X POST "$url" 2>/dev/null || true
}

#############################
# 行打印（数字上色、URL 全量）
#############################
print_dl_status() {
  local tid="$1" url="$2" bytes="$3" tsum="$4" sec="${5:-0}"
  local global_bytes; global_bytes=$(atomic_add "$DL_TOTAL_FILE" "$bytes")
  : > "$COUNTER_DIR/hb.dl.$tid"
  local rate; rate=$(fmt_rate "$bytes" "$sec")
  printf "%s[DL#%s]%s | 本次 %s%6.2f%s MB | 累计 %s%7.2f%s MB | 速率 %s%6s%s MB/s | %s%s%s\n" \
    "${C_CYAN}" "$tid" "${C_RESET}" \
    "${C_YELLOW}" "$(fmt_mb "$bytes")" "${C_RESET}" \
    "${C_GREEN}"  "$(fmt_mb "$tsum")"  "${C_RESET}" \
    "${C_MAGENTA}" "$rate" "${C_RESET}" \
    "${C_BLUE}" "$url" "${C_RESET}"
}
print_ul_status() {
  local tid="$1" url="$2" bytes="$3" tsum="$4" sec="${5:-0}"
  local global_bytes; global_bytes=$(atomic_add "$UL_TOTAL_FILE" "$bytes")
  : > "$COUNTER_DIR/hb.ul.$tid"
  local rate; rate=$(fmt_rate "$bytes" "$sec")
  printf "%s[UL#%s]%s | 本次 %s%6.2f%s MB | 累计 %s%7.2f%s MB | 速率 %s%6s%s MB/s | %s%s%s\n" \
    "${C_MAGENTA}" "$tid" "${C_RESET}" \
    "${C_YELLOW}"  "$(fmt_mb "$bytes")" "${C_RESET}" \
    "${C_GREEN}"   "$(fmt_mb "$tsum")"  "${C_RESET}" \
    "${C_MAGENTA}" "$rate" "${C_RESET}" \
    "${C_BLUE}" "$url" "${C_RESET}"
}

#############################
# 清理辅助（强力，兼容无 pkill）
#############################
safe_pkill_children() {
  local sig="$1" ppid="$2"
  if command -v pkill >/dev/null 2>&1; then
    pkill -"${sig}" -P "$ppid" 2>/dev/null || true
  else
    ps -o pid= --ppid "$ppid" 2>/dev/null | xargs -r kill -"${sig}" 2>/dev/null || true
  fi
}

#############################
# CPU 限制实现
#############################
cores_count() { command -v nproc >/dev/null 2>&1 && nproc || echo 1; }
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
  ((${#CPULIMIT_WATCHERS[@]})) && { for wp in "${CPULIMIT_WATCHERS[@]}"; do kill -TERM "$wp" 2>/dev/null || true; done; CPULIMIT_WATCHERS=(); }
}
cgroup_enter_self() {
  set +e
  [[ "$LIMIT_METHOD" != "cgroup" ]] && { set -e; return 0; }
  if [[ -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
    grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
  fi
  [[ -z "$CGROUP_DIR" ]] && { CGROUP_DIR="/sys/fs/cgroup/vpsburn.$$"; mkdir -p "$CGROUP_DIR" 2>/dev/null || true; }
  [[ -w "$CGROUP_DIR/cgroup.procs" ]] && echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true
  set -e
}
cgroup_set_percent() {
  set +e
  local pct="$1"; [[ "$LIMIT_METHOD" != "cgroup" || -z "$CGROUP_DIR" ]] && { set -e; return 0; }
  local period=${CGROUP_PERIOD_US}
  if (( pct <= 0 || pct >= 100 )); then echo "max" > "$CGROUP_DIR/cpu.max" 2>/dev/null || true; set -e; return 0; fi
  local n; n=$(cores_count); local quota; quota=$(awk -v P="$period" -v N="$n" -v R="$pct" 'BEGIN{printf "%.0f", P*N*R/100}')
  echo "$quota $period" > "$CGROUP_DIR/cpu.max" 2>/dev/null || true
  set -e
}
cpulimit_apply_for_pids() {
  local pct="$1"
  command -v cpulimit >/dev/null 2>&1 || return 0
  ((${#PIDS[@]})) || return 0
  local inc_child_opt=""
  if cpulimit -h 2>&1 | grep -qE -- '-z|children'; then inc_child_opt="-z"; fi
  for pid in "${PIDS[@]}"; do cpulimit -p "$pid" -l "$pct" $inc_child_opt -b >/dev/null 2>&1 & CPULIMIT_WATCHERS+=("$!"); done
}
calc_cpulimit_per_proc() {
  local target_pct="$1" ncores; ncores=$(cores_count); local nprocs=${#PIDS[@]}; (( nprocs<1 )) && nprocs=1
  awk -v tp="$target_pct" -v nc="$ncores" -v np="$nprocs" 'BEGIN{v=tp*nc/np; if(v<1)v=1; if(v>100)v=100; printf "%.0f", v}'
}
limit_apply_percent() {
  set +e
  local pct="$1"; detect_limit_method
  case "$LIMIT_METHOD" in
    cgroup)  cgroup_set_percent "$pct" ;;
    cpulimit)
      if (( pct >= 100 )); then kill_cpulimit_watchers
      else local per; per=$(calc_cpulimit_per_proc "$pct"); cpulimit_apply_for_pids "$per"; fi ;;
    *) (( NONE_WARNED==0 && SUPPRESS_CPUWARN==0 )) && { echo "${C_YELLOW}[!] 无 cgroup写权限且未安装 cpulimit，无法精确限 CPU（仅提示一次）。${C_RESET}"; NONE_WARNED=1; } ;;
  esac
  set -e
}

# 模拟“正常使用”的自适应调度器
rand_between() { local min="$1" max="$2"; echo $(( RANDOM % (max - min + 1) + min )); }
normal_usage_scheduler() {
  local cycle=0
  while true; do
    cycle=$((cycle+1))
    local hour; hour=$(date +%H)
    local base_min base_max burst_p burst_min burst_max
    if (( 8<=10#$hour && 10#$hour<19 )); then base_min=10; base_max=35; burst_p=20; burst_min=40; burst_max=65
    elif (( 1<=10#$hour && 10#$hour<6 )); then base_min=3; base_max=12; burst_p=5;  burst_min=20; burst_max=30
    else base_min=6; base_max=25; burst_p=10; burst_min=30; burst_max=50; fi
    local target dur
    if (( cycle % $(rand_between 6 10) == 0 )); then target=$(rand_between 2 5); dur=$(rand_between 5 15); limit_apply_percent "$target"; sleep "$dur"; continue; fi
    if (( RANDOM % 100 < burst_p )); then target=$(rand_between "$burst_min" "$burst_max"); dur=$(rand_between 10 45)
    else target=$(rand_between "$base_min" "$base_max"); dur=$(rand_between 30 180); fi
    (( target<1 )) && target=1; (( target>90 )) && target=90
    limit_apply_percent "$target"; sleep "$dur"
  done
}
start_normal_usage() { is_scheduler_running || { normal_usage_scheduler & LIMITER_PID=$!; echo "${C_GREEN}[*] 已启用：模拟正常使用。${C_RESET}"; }; }
stop_normal_usage() { kill_scheduler; }

limit_set_mode() {
  set +e
  local mode="$1"; detect_limit_method
  case "$mode" in
    0) LIMIT_MODE=0; stop_normal_usage; kill_cpulimit_watchers; limit_apply_percent 100; echo "${C_GREEN}[+] 已清除 CPU 限制。${C_RESET}" ;;
    1) LIMIT_MODE=1; stop_normal_usage; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; limit_apply_percent 50; echo "${C_GREEN}[+] 已设置恒定 50%。${C_RESET}" ;;
    2) LIMIT_MODE=2; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; start_normal_usage ;;
  esac
  set -e
}
ensure_limit_on_current_run() {
  (( LIMIT_MODE==0 )) && return 0
  detect_limit_method
  if [[ "$LIMIT_METHOD" == "cgroup" ]]; then
    (( LIMIT_MODE==1 )) && limit_apply_percent 50
    (( LIMIT_MODE==2 )) && start_normal_usage
  elif [[ "$LIMIT_METHOD" == "cpulimit" ]]; then
    (( LIMIT_MODE==1 )) && { local per; per=$(calc_cpulimit_per_proc 50); cpulimit_apply_for_pids "$per"; }
    (( LIMIT_MODE==2 )) && start_normal_usage
  fi
}

#############################
# 线程启动/重启（看门狗用）
#############################
spawn_dl() { local id="$1"; download_worker "$id" & local pid=$!; DL_PIDS["$id"]=$pid; PIDS+=("$pid"); }
spawn_ul() { local id="$1"; upload_worker "$id" & local pid=$!; UL_PIDS["$id"]=$pid; PIDS+=("$pid"); }

#############################
# 工作线程
#############################
download_worker() {
  local id="$1"; local thread_sum=0
  while true; do
    (( END_TS > 0 )) && (( $(date +%s) >= END_TS )) && break
    local url; url="$(pick_active_dl_url)"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_dl_thread_bps)
    local bytes=0 time_s=0 code="000"

    if (( ALWAYS_CHUNK )); then
      local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
      local res2; res2=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps")
      if [[ -n "$res2" ]]; then bytes="${res2%% *}"; time_s="${res2#* }"; fi
    else
      local res; res="$(curl_measure_full "$final" "$limit_bps")"
      if [[ -n "$res" ]]; then bytes="${res%% *}"; res="${res#* }"; time_s="${res%% *}"; res="${res#* }"; code="${res%% *}"; fi
      if [[ -z "$bytes" || "$bytes" == "0" || ( "$code" != "200" && "$code" != "206" ) ]]; then
        local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
        local res2; res2=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps")
        if [[ -n "$res2" ]]; then bytes="${res2%% *}"; time_s="${res2#* }"; fi
      fi
    fi

    (( bytes > 0 )) && mark_url_ok "$url" || mark_url_fail "$url"
    thread_sum=$((thread_sum + bytes))
    print_dl_status "$id" "$final" "$bytes" "$thread_sum" "$time_s"
  done
}
upload_worker() {
  local id="$1"; local thread_sum=0
  while true; do
    (( END_TS > 0 )) && (( $(date +%s) >= END_TS )) && break
    local url; url="$(pick_active_ul_url)"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_ul_thread_bps)
    local chunk_bytes=$(( CHUNK_MB_UL*1048576 ))
    local res; res="$(curl_measure_upload "$final" "$chunk_bytes" "$limit_bps")"
    local bytes=0 code="000" time_s=0
    if [[ -n "$res" ]]; then bytes="${res%% *}"; res="${res#* }"; time_s="${res%% *}"; res="${res#* }"; code="${res%% *}"; fi
    if [[ "$code" != "200" && "$code" != "204" && "$code" != "201" && "$code" != "202" ]]; then bytes=0; sleep 1; fi
    (( bytes > 0 )) && mark_url_ok "$url" || mark_url_fail "$url"
    thread_sum=$((thread_sum + bytes))
    print_ul_status "$id" "$final" "$bytes" "$thread_sum" "$time_s"
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
  (( SUMMARY_INTERVAL > 0 )) || return 0
  if is_summary_running; then echo "${C_YELLOW}[*] 定时汇总已在运行。${C_RESET}"
  else summary_worker & SUMMARY_PID=$!; echo "${C_GREEN}[*] 已开启定时汇总（每 ${SUMMARY_INTERVAL}s）。${C_RESET}"; fi
}
stop_summary() {
  if is_summary_running; then kill -TERM "$SUMMARY_PID" 2>/dev/null || true; wait "$SUMMARY_PID" 2>/dev/null || true; SUMMARY_PID=; echo "${C_GREEN}[+] 已停止定时汇总。${C_RESET}"; fi
}
configure_summary() {
  echo "当前定时汇总：$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo \"每 ${SUMMARY_INTERVAL}s\" || echo '关闭')"
  read -rp "输入间隔秒（0=关闭，留空不变）: " v || true
  [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    SUMMARY_INTERVAL="$v"
    stop_summary
    (( SUMMARY_INTERVAL > 0 )) && start_summary
    echo "${C_GREEN}[+] 定时汇总已设置为：$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo \"每 ${SUMMARY_INTERVAL}s\" || echo '关闭')${C_RESET}"
  else
    echo "${C_YELLOW}输入无效。${C_RESET}"
  fi
}

#############################
# 看门狗（心跳文件）
#############################
watchdog_loop() {
  while true; do
    sleep "$WATCHDOG_INTERVAL"
    (( WATCHDOG_ENABLE==1 )) || continue
    local now; now=$(now_epoch)

    for id in "${!DL_PIDS[@]}"; do
      local hb="$COUNTER_DIR/hb.dl.$id" pid="${DL_PIDS[$id]:-}"
      [[ -z "$pid" || -z "$hb" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        local mt=0; [[ -f "$hb" ]] && mt=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo 0)
        if (( mt>0 && now-mt > WATCHDOG_STALL )); then
          if (( WATCHDOG_MAX_RESTARTS==0 || ${DL_RESTARTS[$id]:-0} < WATCHDOG_MAX_RESTARTS )); then
            echo "${C_YELLOW}[WD] DL#$id 心跳超时（>${WATCHDOG_STALL}s），重启…${C_RESET}"
            safe_pkill_children TERM "$pid"; kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
            DL_RESTARTS["$id"]=$(( ${DL_RESTARTS[$id]:-0} + 1 ))
            spawn_dl "$id"
          fi
        fi
      fi
    done

    for id in "${!UL_PIDS[@]}"; do
      local hb="$COUNTER_DIR/hb.ul.$id" pid="${UL_PIDS[$id]:-}"
      [[ -z "$pid" || -z "$hb" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        local mt=0; [[ -f "$hb" ]] && mt=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo 0)
        if (( mt>0 && now-mt > WATCHDOG_STALL )); then
          if (( WATCHDOG_MAX_RESTARTS==0 || ${UL_RESTARTS[$id]:-0} < WATCHDOG_MAX_RESTARTS )); then
            echo "${C_YELLOW}[WD] UL#$id 心跳超时（>${WATCHDOG_STALL}s），重启…${C_RESET}"
            safe_pkill_children TERM "$pid"; kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
            UL_RESTARTS["$id"]=$(( ${UL_RESTARTS[$id]:-0} + 1 ))
            spawn_ul "$id"
          fi
        fi
      fi
    done
  done
}

#############################
# 启停控制 & 智能分配
#############################
init_and_check() { check_curl || return 1; init_counters; }

wait_first_output() {
  (( START_WAIT_FIRST_OUTPUT )) || return 0
  for ((i=0; i<START_WAIT_SPINS; i++)); do
    [[ -f "$COUNTER_DIR/hb.dl.1" || -f "$COUNTER_DIR/hb.ul.1" ]] && return 0
    sleep 0.1
  done
}

smart_split_threads() {
  local total="$1" extra_side dl_pos ul_pos cmp
  if (( total <= 1 )); then DL_THREADS=1; UL_THREADS=0; return; fi
  if (( total % 2 == 0 )); then DL_THREADS=$(( total/2 )); UL_THREADS=$(( total/2 )); return; fi
  extra_side="ul"
  dl_pos=$(awk -v x="$DL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  ul_pos=$(awk -v x="$UL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  if (( dl_pos==1 || ul_pos==1 )); then
    if   (( dl_pos==1 && ul_pos==0 )); then extra_side="dl"
    elif (( dl_pos==0 && ul_pos==1 )); then extra_side="ul"
    else cmp=$(awk -v dl="$DL_LIMIT_MB" -v ul="$UL_LIMIT_MB" 'BEGIN{if(dl<ul) print "dl"; else print "ul"}'); extra_side="$cmp"; fi
  fi
  if [[ "$extra_side" == "dl" ]]; then DL_THREADS=$(( total/2 + 1 )); UL_THREADS=$(( total - DL_THREADS ))
  else UL_THREADS=$(( total/2 + 1 )); DL_THREADS=$(( total - UL_THREADS )); fi
}

start_consumption() {
  local mode="$1" dl_n="$2" ul_n="$3"
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }
  init_and_check || { echo "${C_RED}无法启动：初始化失败（可能 /tmp 无空间或未安装 curl）。${C_RESET}"; return 1; }
  MODE="$mode"; PIDS=(); DL_PIDS=(); UL_PIDS=(); DL_RESTARTS=(); UL_RESTARTS=()

  echo "${C_BOLD}[*] $(human_now) 启动：模式=${MODE}  下载线程=${dl_n}  上传线程=${ul_n}${C_RESET}"
  echo "[*] 定时汇总：$( ((SUMMARY_INTERVAL>0)) && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭" )"
  (( END_TS > 0 )) && echo "[*] 预计停止于：$(date_human_ts "$END_TS")"

  if (( LIMIT_MODE>0 )); then detect_limit_method; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; fi

  if [[ "$MODE" != "u" ]] && (( dl_n > 0 )); then
    for ((i=1; i<=dl_n; i++)); do : > "$COUNTER_DIR/hb.dl.$i"; spawn_dl "$i"; sleep 0.05; done
  fi
  if [[ "$MODE" != "d" ]] && (( ul_n > 0 )); then
    for ((i=1; i<=ul_n; i++)); do : > "$COUNTER_DIR/hb.ul.$i"; spawn_ul "$i"; sleep 0.05; done
  fi

  start_summary
  if (( WATCHDOG_ENABLE==1 )); then watchdog_loop & WATCHDOG_PID=$!; fi

  echo "${C_GREEN}[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 或选菜单 3 可停止。${C_RESET}"
  wait_first_output
  ensure_limit_on_current_run
}

# stop_consumption [quiet_flag]
# quiet_flag=1 时：使用你指定的提示格式，且静默 CPU 限制警告
stop_consumption() {
  local quiet="${1:-0}"
  SUPPRESS_CPUWARN=1

  # 统一起始提示（仅 quiet=1 时打印你要的固定格式）
  if (( quiet )); then
    printf "[*] %s 正在停止全部线程…\n" "$(human_now)"
  else
    echo "${C_BOLD}[*] $(human_now) 正在停止全部线程…${C_RESET}"
  fi

  # 杀掉 watchdog + 调度器 + 恢复CPU限额
  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=
  fi
  kill_scheduler
  limit_apply_percent 100

  # 杀掉全部工作线程及其后代
  if ! is_running; then
    : # 没有在跑
  else
    for pid in "${PIDS[@]}"; do
      safe_pkill_children TERM "$pid"; kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
    for pid in "${PIDS[@]}"; do
      safe_pkill_children KILL "$pid"; kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    PIDS=(); DL_PIDS=(); UL_PIDS=()
  fi
  kill_cpulimit_watchers
  stop_summary

  # 最终汇总 + 清理
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  if (( quiet )); then
    printf "[*] 最终汇总：下载总计 %s MB；上传总计 %s MB\n" "$(bytes_to_mb "$dl_g")" "$(bytes_to_mb "$ul_g")"
    echo "[+] 已全部停止。"
  else
    echo "${C_BOLD}[*] 最终汇总：下载总计 ${C_CYAN}$(bytes_to_mb "$dl_g") MB${C_RESET}${C_BOLD}；上传总计 ${C_MAGENTA}$(bytes_to_mb "$ul_g") MB${C_RESET}"
    echo "${C_GREEN}[+] 已全部停止。${C_RESET}"
  fi
  cleanup_counters
  # 清除 cgroup 目录（若已创建）
  if [[ -n "${CGROUP_DIR:-}" && -d "$CGROUP_DIR" ]]; then rmdir "$CGROUP_DIR" 2>/dev/null || true; fi
}

#############################
# 交互：启动（默认=3 同时）
#############################
list_download_urls() { echo; echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }
list_upload_urls() { echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }

interactive_start() {
  echo; echo "${C_BOLD}请选择消耗模式：${C_RESET}"
  echo "  1) 下载（仅下行）"; echo "  2) 上传（仅上行）"; echo "  3) 同时（上下行）"
  read -rp "模式 [1-3]（默认 3）: " mode_num || true
  [[ -z "${mode_num// /}" ]] && mode_num=3
  case "$mode_num" in 1) MODE="d" ;; 2) MODE="u" ;; 3) MODE="b" ;; *) echo "${C_YELLOW}[!] 输入无效，默认同时。${C_RESET}"; MODE="b" ;; esac

  read -rp "并发线程数（留空自动）: " t || true
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
    read -rp "上传地址编号（逗号分隔，留空=全量随机）: " pick_ul || true
    if [[ -z "${pick_ul// /}" ]]; then
      ACTIVE_UPLOAD_URLS=( "${UPLOAD_URLS[@]}" )
      echo "[*] 未选择编号：默认使用全量上传地址随机轮换（${#UPLOAD_URLS[@]} 个）"
    else
      parse_choice_to_array "${pick_ul:-}" UPLOAD_URLS ACTIVE_UPLOAD_URLS
    fi
  else
    ACTIVE_UPLOAD_URLS=()
  fi

  read -rp "运行多久（单位=小时，留空=一直运行）: " hours || true
  if [[ -z "${hours// /}" ]]; then END_TS=0; echo "[*] 将一直运行，直到手动停止。"
  elif [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then local secs; secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}'); END_TS=$(( $(date +%s) + secs )); echo "[*] 预计停止于：$(date_human_ts "$END_TS")"
  else echo "${C_YELLOW}[!] 非法输入，改为一直运行。${C_RESET}"; END_TS=0; fi

  if [[ "$MODE" == "b" ]]; then smart_split_threads "$total_threads"
  elif [[ "$MODE" == "d" ]]; then DL_THREADS="$total_threads"; UL_THREADS=0
  else DL_THREADS=0; UL_THREADS="$total_threads"; fi

  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS"
}

#############################
# 解析选择
#############################
parse_choice_to_array() {
  local input="$1" src="$2" dst="$3"
  local -n _SRC="$src"; local -n _DST="$dst"; _DST=()
  [[ -z "${input// /}" ]] && { _DST=("${_SRC[@]}"); return; }
  IFS=',' read -r -a idxs <<<"$input"
  for raw in "${idxs[@]}"; do
    local n="${raw//[[:space:]]/}"; [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n>=1 && n<=${#_SRC[@]} )) || continue
    _DST+=("${_SRC[$((n-1))]}")
  done
  [[ ${#_DST[@]} -gt 0 ]] || _DST=("${_SRC[@]}")
}

#############################
# 限速设置（仅脚本进程）
#############################
configure_limits() {
  echo "${C_BOLD}当前限速（总速，MB/s）：DL=${DL_LIMIT_MB}，UL=${UL_LIMIT_MB}${C_RESET}"
  echo "  1) 限制上传总速"; echo "  2) 限制下载总速"; echo "  3) 同时限速"; echo "  4) 清除限速"
  read -rp "选择 [1-4]: " sub || true
  case "${sub:-}" in
    1) read -rp "输入上传总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 上传总速 = ${UL_LIMIT_MB} MB/s。${C_RESET}"; else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    2) read -rp "输入下载总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 下载总速 = ${DL_LIMIT_MB} MB/s。${C_RESET}"; else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    3) read -rp "输入上下行总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }
       if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DL_LIMIT_MB="$v"; UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 上下行总速 = ${v} MB/s。${C_RESET}"; else echo "${C_YELLOW}[-] 输入无效。${C_RESET}"; fi ;;
    4) DL_LIMIT_MB=0; UL_LIMIT_MB=0; echo "${C_GREEN}[+] 已清除全部限速。${C_RESET}";;
    *) echo "${C_YELLOW}无效选择。${C_RESET}";;
  esac
  if (( DL_LIMIT_MB > 0 && DL_THREADS > 0 )); then local per=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}'); echo "  下载每线程≈ ${per} MB/s"; fi
  if (( UL_LIMIT_MB > 0 && UL_THREADS > 0 )); then local per=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}'); echo "  上传每线程≈ ${per} MB/s"; fi
  echo "${C_DIM}（说明：限速仅作用于本脚本启动的 curl，不影响系统其他进程）${C_RESET}"
}

#############################
# 限制模式菜单（CPU）
#############################
configure_cpu_limit_mode() {
  echo "${C_BOLD}限制模式（CPU）：${C_RESET}当前 = $(case "$LIMIT_MODE" in 0) echo 关闭;; 1) echo 恒定50%;; 2) echo 模拟正常使用;; esac)"
  echo "  1) 恒定 50%"; echo "  2) 模拟正常使用（随机/突发/夜间低负载）"; echo "  3) 清除限制"
  read -rp "选择 [1-3]: " lm || true
  case "${lm:-}" in 1) limit_set_mode 1 ;; 2) limit_set_mode 2 ;; 3) limit_set_mode 0 ;; *) echo "${C_YELLOW}无效选择，未更改。${C_RESET}" ;; esac
  echo "${C_DIM}说明：优先 cgroup v2；否则退回 cpulimit；模拟模式周期性调整目标负载并穿插短突发与休息窗口。${C_RESET}"
}

#############################
# 菜单
#############################
menu() {
  while true; do
    echo
    show_status
    read -rp "${C_BOLD}请选择 [0-6] > ${C_RESET}" c || true
    case "${c:-}" in
      1) interactive_start        ;;
      2) configure_cpu_limit_mode ;;
      3) stop_consumption 0       ;;
      4) show_urls                ;;
      5) configure_summary        ;;
      6) configure_limits         ;;
      0) echo "[!] 捕获到信号，正在清理…"; stop_consumption 1; exit 0 ;;
      *) echo "${C_YELLOW}无效选择。${C_RESET}" ;;
    esac
  done
}

menu
