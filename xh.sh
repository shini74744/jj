#!/usr/bin/env bash
# 流量消耗/测速脚本（纯文本主菜单 + 实时行输出 + 看门狗 + 熔断 + 仅脚本限速 + CPU行为模拟 + 干净退出）
# 关键修复：
# - 主进程统一监督任务；独立进程组确保信号退出不遗留上传后代
# - 阻塞用 kill -0 轮询子进程是否存活，完全移除 wait/-n 依赖
# - EXIT/INT/TERM/HUP 幂等清理；小数限速与慢请求心跳兼容
# - Ctrl+C/HUP 都会触发 4 行简洁收尾；URL 全显；数字着色；作者/探针标红

set -Euo pipefail
set +m  # 每个后台任务用 setsid 创建独立进程组，不能开启 shell job control。

AUTHOR="${AUTHOR:-大大怪}"
PROBE_ADDR="${PROBE_ADDR:-nmsl.ma}"

# 行为控制
EXIT_AFTER_STOP=${EXIT_AFTER_STOP:-1}      # 1=停止后直接退出脚本；0=回菜单
FOLLOW_AFTER_START=${FOLLOW_AFTER_START:-1} # 1=开始后前台阻塞输出
CGROUP_PERIOD_US=${CGROUP_PERIOD_US:-20000}

# 默认参数
DEFAULT_THREADS=${DEFAULT_THREADS:-6}
SUMMARY_INTERVAL=${SUMMARY_INTERVAL:-0}
IP_VERSION=${IP_VERSION:-4}      # 4/6/0(自动)
FORCE_HTTP1=${FORCE_HTTP1:-1}
ALWAYS_CHUNK=${ALWAYS_CHUNK:-1}
CHUNK_MB_DL=${CHUNK_MB_DL:-50}
CHUNK_MB_UL=${CHUNK_MB_UL:-10}
START_WAIT_FIRST_OUTPUT=${START_WAIT_FIRST_OUTPUT:-1}
START_WAIT_SPINS=${START_WAIT_SPINS:-30}

# curl 相关
CURL_CONNECT_TIMEOUT=${CURL_CONNECT_TIMEOUT:-5}
CURL_MAX_TIME=${CURL_MAX_TIME:-60}
CURL_SPEED_TIME=${CURL_SPEED_TIME:-8}
CURL_SPEED_LIMIT=${CURL_SPEED_LIMIT:-131072}

# 看门狗
WATCHDOG_ENABLE=${WATCHDOG_ENABLE:-1}
WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL:-5}
WATCHDOG_STALL=${WATCHDOG_STALL:-20}
WATCHDOG_MAX_RESTARTS=${WATCHDOG_MAX_RESTARTS:-0}

# 颜色
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

# curl 版本/IP 选项
CURL_IP_OPT=(); HTTP_VER_OPT=()
case "${IP_VERSION}" in 4) CURL_IP_OPT+=(-4);; 6) CURL_IP_OPT+=(-6);; 0) :;; esac
(( FORCE_HTTP1 )) && HTTP_VER_OPT+=(--http1.1)
auto_pick_ip_version() {
  [[ "${IP_VERSION:-0}" != "0" ]] && return
  if curl -6 -I -s --connect-timeout 2 https://www.cloudflare.com >/dev/null 2>&1; then CURL_IP_OPT=(-6); else CURL_IP_OPT=(-4); fi
}
auto_pick_ip_version

# 下载/上传地址池
URLS=(
  "https://speed.cloudflare.com/static/1GB.bin"
  "https://nbg1-speed.hetzner.com/100MB.bin"
  "https://nbg1-speed.hetzner.com/1GB.bin"
  "https://fsn1-speed.hetzner.com/100MB.bin"
  "https://fsn1-speed.hetzner.com/1GB.bin"
  "https://hel1-speed.hetzner.com/100MB.bin"
  "https://hel1-speed.hetzner.com/1GB.bin"
  "https://ash-speed.hetzner.com/100MB.bin"
  "https://ash-speed.hetzner.com/1GB.bin"
  "https://hil1-speed.hetzner.com/100MB.bin"
  "https://hil1-speed.hetzner.com/1GB.bin"
  "https://sin-speed.hetzner.com/100MB.bin"
  "https://sin-speed.hetzner.com/1GB.bin"
  "https://speed.cloudflare.com/__down?bytes=104857600"
  "https://speed.cloudflare.com/__down?during=download&bytes=1073741824"
  "https://store.storevideos.cdn-apple.com/v1/store.apple.com/st/1666383693478/atvloop-video-202210/streams_atvloop-video-202210/1920x1080/fileSequence3.m4s"
)
UPLOAD_URLS=(
  "https://speed.cloudflare.com/__up"
  "https://fancy-feather-6ba1.7474483.workers.dev/"
)

# 运行状态
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
STOPPED=0

declare -A DL_PIDS UL_PIDS
declare -A DL_RESTARTS UL_RESTARTS
LIMIT_MODE=0
LIMIT_METHOD=""
CGROUP_DIR=""
LIMITER_PID=
CPULIMIT_WATCHERS=()
NONE_WARNED=0
WATCHDOG_PID=
WATCHDOG_NEXT=0
SUMMARY_NEXT=0
LIMITER_NEXT=0
LIMITER_CYCLE=0
RUNNING=0
declare -A URL_FAILS URL_COOLDOWN

# 工具
now_epoch(){ date +%s; }
term_cols(){ command -v tput >/dev/null 2>&1 && tput cols || echo 80; }
repeat_char(){ local n="$1" ch="${2:--}"; printf "%*s" "$n" "" | tr ' ' "$ch"; }
bytes_to_mb(){ awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }
fmt_mb(){ awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }
fmt_rate(){ local b="$1" s="$2"; awk -v b="$b" -v s="$s" 'BEGIN{ if(s<=0.000001){print "—"} else printf "%.2f", (b/1048576)/s }'; }
human_now(){ date "+%F %T"; }
date_human_ts(){ if date -d @0 +%F >/dev/null 2>&1; then date -d @"$1" "+%F %T"; elif date -r 0 +%F >/dev/null 2>&1; then date -r "$1" "+%F %T"; else echo "$1"; fi; }
auto_threads(){ local c=1; command -v nproc >/dev/null 2>&1 && c=$(nproc) || { [[ -r /proc/cpuinfo ]] && c=$(grep -c '^processor' /proc/cpuinfo || echo 1); }; local t=$((c*2)); ((t<4))&&t=4; ((t>32))&&t=32; echo "$t"; }
check_curl(){ command -v curl >/dev/null 2>&1 || { echo "${C_RED}[-] 未检测到 curl，请先安装 ca-certificates 与 curl。${C_RESET}"; return 1; }; }

# 计数器
init_counters(){
  local bases=(); [[ -n "${TMPDIR:-}" ]] && bases+=("$TMPDIR"); bases+=("/dev/shm" "/var/tmp" ".")
  COUNTER_DIR=""
  for b in "${bases[@]}"; do
    [[ -d "$b" && -w "$b" ]] || continue
    COUNTER_DIR="$(mktemp -d -p "$b" vpsburn.XXXXXX 2>/dev/null)" || true
    [[ -n "$COUNTER_DIR" ]] && break
  done
  [[ -n "$COUNTER_DIR" ]] || { echo "${C_RED}[-] 无法创建临时目录。${C_RESET}"; return 1; }
  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE"
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE"
}
cleanup_counters(){ [[ -n "$COUNTER_DIR" ]] && rm -rf "$COUNTER_DIR" 2>/dev/null || true; }
atomic_add(){
  local f="$1" add="$2"
  if command -v flock >/dev/null 2>&1; then
    (exec 9<>"${f}.lock"; flock -x 9; local cur=0; [[ -f "$f" ]] && cur=$(cat "$f" 2>/dev/null || echo 0); echo $((cur+add)) > "$f"; cat "$f")
  else
    local cur=0; [[ -f "$f" ]] && cur=$(cat "$f" 2>/dev/null || echo 0); echo $((cur+add)) > "$f"; cat "$f"
  fi
}

# 熔断
url_on_cooldown(){ local u="$1" now; now=$(now_epoch); local until="${URL_COOLDOWN[$u]:-0}"; ((now<until)); }
mark_url_fail(){ local u="$1" n=$(( ${URL_FAILS[$u]:-0}+1 )); URL_FAILS[$u]=$n; URL_COOLDOWN[$u]=$(( $(now_epoch)+5*n )); }
mark_url_ok(){ local u="$1"; URL_FAILS[$u]=0; URL_COOLDOWN[$u]=0; }
pick_active_dl_url(){ local c=() u; for u in "${ACTIVE_URLS[@]}"; do url_on_cooldown "$u" || c+=("$u"); done; ((${#c[@]}==0))&&c=("${ACTIVE_URLS[@]}"); echo "${c[RANDOM%${#c[@]}]}"; }
pick_active_ul_url(){ local c=() u; for u in "${ACTIVE_UPLOAD_URLS[@]}"; do url_on_cooldown "$u" || c+=("$u"); done; ((${#c[@]}==0))&&c=("${ACTIVE_UPLOAD_URLS[@]}"); echo "${c[RANDOM%${#c[@]}]}"; }

# UI
show_status(){
  local cols; cols=$(term_cols); ((cols<70))&&cols=70
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  local dl_thr="-" ul_thr="-"
  positive_rate "$DL_LIMIT_MB" && (( DL_THREADS>0 )) && dl_thr=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
  positive_rate "$UL_LIMIT_MB" && (( UL_THREADS>0 )) && ul_thr=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
  local line; line="$(repeat_char "$cols" "-")"
  local summary_text=$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo "每 ${SUMMARY_INTERVAL}s" || echo "关闭")
  local end_text=$([[ $END_TS -gt 0 ]] && date_human_ts "$END_TS" || echo "手动停止")
  local cpu_text; case "$LIMIT_MODE" in 0) cpu_text="关闭";; 1) cpu_text="恒定50%";; 2) cpu_text="模拟正常使用";; esac

  echo "${C_BOLD}=== 流量消耗/测速 工具 ===${C_RESET}"
  echo "$line"
  printf "运行状态 : %s\n" "$(( ${#PIDS[@]} > 0 )) && echo 运行中 || echo 未运行"
  printf "当前模式 : %s\n" "${MODE:-N/A}"
  printf "作者     : ${C_RED}%s${C_RESET}\n" "${AUTHOR}"
  printf "探针地址 : ${C_RED}%s${C_RESET}\n" "${PROBE_ADDR}"
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

# 限速
positive_rate(){ awk -v x="$1" 'BEGIN{exit !(x+0>0)}'; }
calc_dl_thread_bps(){ positive_rate "$DL_LIMIT_MB" && (( DL_THREADS>0 )) && awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1)v=1; printf "%.0f", v}' || echo 0; }
calc_ul_thread_bps(){ positive_rate "$UL_LIMIT_MB" && (( UL_THREADS>0 )) && awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{v=mb*1048576/n; if(v<1)v=1; printf "%.0f", v}' || echo 0; }

# curl 封装
append_nocache(){ local url="$1" tag="$2"; local s="nocache=$(date +%s%N)-${tag}-$RANDOM"; [[ "$url" == *\?* ]] && echo "${url}&${s}" || echo "${url}?${s}"; }
curl_measure_dl_range(){
  local url="$1" range_end="$2" limit_bps="${3:-0}" extra=()
  transfer_begin 3
  (( limit_bps>0 )) && extra+=(--limit-rate "$limit_bps")
  curl -sS -L "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry 2 --retry-all-errors \
    --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
    -A "Mozilla/5.0" -H "Range: bytes=0-${range_end}" \
    "${extra[@]}" -w '%{size_download} %{time_total}' -o /dev/null "$url" 2>/dev/null || true
}
curl_measure_full(){
  local url="$1" limit_bps="${2:-0}" extra=()
  transfer_begin 4
  (( limit_bps>0 )) && extra+=(--limit-rate "$limit_bps")
  local max_bytes=$((128*1024*1024))
  curl -sS -L "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
    --max-filesize "$max_bytes" \
    -A "Mozilla/5.0" "${extra[@]}" \
    -w '%{size_download} %{time_total} %{http_code} %{url_effective}' \
    -o /dev/null "$url" 2>/dev/null || true
}
curl_measure_upload(){
  local url="$1" bytes="$2" limit_bps="${3:-0}" extra=()
  transfer_begin 3
  (( limit_bps>0 )) && extra+=(--limit-rate "$limit_bps")
  head -c "$bytes" /dev/zero | curl -sS -L "${CURL_IP_OPT[@]}" "${HTTP_VER_OPT[@]}" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --retry 2 --retry-all-errors \
    --speed-time "$CURL_SPEED_TIME" --speed-limit "$CURL_SPEED_LIMIT" \
    -A "Mozilla/5.0" -H "Content-Type: application/octet-stream" \
    "${extra[@]}" --data-binary @- \
    -w '%{size_upload} %{time_total} %{http_code}' \
    -o /dev/null -X POST "$url" 2>/dev/null || true
}

# 行输出（数字着色，URL 全显）
print_dl_status(){
  local id="$1" url="$2" bytes="$3" tsum="$4" sec="${5:-0}"
  local _; _=$(atomic_add "$DL_TOTAL_FILE" "$bytes"); : > "$COUNTER_DIR/hb.dl.$id"
  local rate; rate=$(fmt_rate "$bytes" "$sec")
  printf "%s[DL#%s]%s | 本次 %s%6.2f MB%s | 累计 %s%7.2f MB%s | 速率 %s%6s MB/s%s | %s\n" \
    "${C_CYAN}" "$id" "${C_RESET}" \
    "${C_YELLOW}" "$(fmt_mb "$bytes")" "${C_RESET}" \
    "${C_GREEN}"  "$(fmt_mb "$tsum")"  "${C_RESET}" \
    "${C_MAGENTA}" "$rate"              "${C_RESET}" \
    "$url"
}
print_ul_status(){
  local id="$1" url="$2" bytes="$3" tsum="$4" sec="${5:-0}"
  local _; _=$(atomic_add "$UL_TOTAL_FILE" "$bytes"); : > "$COUNTER_DIR/hb.ul.$id"
  local rate; rate=$(fmt_rate "$bytes" "$sec")
  printf "%s[UL#%s]%s | 本次 %s%6.2f MB%s | 累计 %s%7.2f MB%s | 速率 %s%6s MB/s%s | %s\n" \
    "${C_MAGENTA}" "$id" "${C_RESET}" \
    "${C_YELLOW}"  "$(fmt_mb "$bytes")" "${C_RESET}" \
    "${C_GREEN}"   "$(fmt_mb "$tsum")"  "${C_RESET}" \
    "${C_CYAN}"    "$rate"              "${C_RESET}" \
    "$url"
}


# 所有需要清理的任务都由主进程创建，并保留独立的进程组。
terminate_group(){
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid>1 && pid!=$$ )) || return 0
  # setsid 完成前可能尚未创建组；同时处理已退出组长留下的后代。
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -- "-$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 0
}
forget_worker(){
  local old="$1" pid kept=()
  for pid in "${PIDS[@]}"; do [[ "$pid" == "$old" ]] || kept+=("$pid"); done
  PIDS=("${kept[@]}")
}
write_runtime_limits(){
  [[ -n "$COUNTER_DIR" && -d "$COUNTER_DIR" ]] || return 0
  printf '%s %s\n' "$DL_LIMIT_MB" "$UL_LIMIT_MB" > "$COUNTER_DIR/limits.new"
  mv -f -- "$COUNTER_DIR/limits.new" "$COUNTER_DIR/limits"
}
worker_tick(){
  [[ -r "$COUNTER_DIR/limits" ]] && read -r DL_LIMIT_MB UL_LIMIT_MB < "$COUNTER_DIR/limits"
  : > "$COUNTER_DIR/hb.$WORKER_KIND.$WORKER_ID"
  return 0
}
transfer_begin(){
  # 心跳只在请求完成后更新；请求和重试期间不能按 20 秒阈值误杀。
  local attempts="$1"
  printf '%s\n' "$(( $(now_epoch) + CURL_MAX_TIME*attempts + WATCHDOG_STALL + 10 ))" > "$COUNTER_DIR/busy.$WORKER_KIND.$WORKER_ID"
}
transfer_end(){
  : > "$COUNTER_DIR/hb.$WORKER_KIND.$WORKER_ID"
  rm -f -- "$COUNTER_DIR/busy.$WORKER_KIND.$WORKER_ID"
}
prepare_worker_script(){
  # 不重新读取 /dev/fd/63：这样也支持 bash <(curl ...) 启动方式。
  {
    printf 'set -uo pipefail\nset +m\n'
    declare -p AUTHOR PROBE_ADDR END_TS CURL_IP_OPT HTTP_VER_OPT CURL_CONNECT_TIMEOUT CURL_MAX_TIME CURL_SPEED_TIME CURL_SPEED_LIMIT ALWAYS_CHUNK CHUNK_MB_DL CHUNK_MB_UL COUNTER_DIR DL_TOTAL_FILE UL_TOTAL_FILE DL_LIMIT_MB UL_LIMIT_MB DL_THREADS UL_THREADS ACTIVE_URLS ACTIVE_UPLOAD_URLS URL_FAILS URL_COOLDOWN CGROUP_DIR WATCHDOG_STALL
    declare -p C_RESET C_BOLD C_DIM C_RED C_GREEN C_BLUE C_YELLOW C_MAGENTA C_CYAN C_WHITE
    declare -f
    cat <<'WORKER'
trap 'exit 0' INT TERM HUP
WORKER_KIND="$1"; WORKER_ID="$2"
if [[ -n "$CGROUP_DIR" && -w "$CGROUP_DIR/cgroup.procs" ]]; then
  printf '%s\n' "$$" > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true
fi
if [[ "$WORKER_KIND" == dl ]]; then download_worker "$WORKER_ID"; else upload_worker "$WORKER_ID"; fi
WORKER
  } > "$COUNTER_DIR/worker.sh"
  chmod 600 "$COUNTER_DIR/worker.sh"
}
spawn_worker(){
  local kind="$1" id="$2" pid
  : > "$COUNTER_DIR/hb.$kind.$id"
  rm -f -- "$COUNTER_DIR/busy.$kind.$id"
  setsid bash "$COUNTER_DIR/worker.sh" "$kind" "$id" &
  pid=$!
  PIDS+=("$pid")
  if [[ "$kind" == dl ]]; then DL_PIDS["$id"]=$pid; else UL_PIDS["$id"]=$pid; fi
}

# CPU 限制
cores_count(){ command -v nproc >/dev/null 2>&1 && nproc || echo 1; }
detect_limit_method(){
  if [[ -z "$LIMIT_METHOD" ]]; then
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qw cpu /sys/fs/cgroup/cgroup.controllers && [[ -w /sys/fs/cgroup ]]; then LIMIT_METHOD="cgroup"
    elif command -v cpulimit >/dev/null 2>&1; then LIMIT_METHOD="cpulimit"
    else LIMIT_METHOD="none"; fi
  fi
}

is_scheduler_running(){ (( LIMITER_NEXT>0 )); }
kill_scheduler(){ LIMITER_NEXT=0; LIMITER_PID=; return 0; }
kill_cpulimit_watchers(){
  local pid
  for pid in "${CPULIMIT_WATCHERS[@]}"; do terminate_group "$pid"; done
  CPULIMIT_WATCHERS=()
  return 0
}
cgroup_enter_self(){
  # 只把本脚本的 worker 放入专用组，主控留在原组；不改宿主根控制器。
  [[ "$LIMIT_METHOD" == cgroup ]] || return 0
  if [[ -z "$CGROUP_DIR" ]]; then
    CGROUP_DIR="/sys/fs/cgroup/vpsburn.$$"
    if ! mkdir -- "$CGROUP_DIR" 2>/dev/null; then CGROUP_DIR=; LIMIT_METHOD=none; return 0; fi
  fi
  if [[ ! -w "$CGROUP_DIR/cpu.max" ]]; then
    rmdir -- "$CGROUP_DIR" 2>/dev/null || true
    CGROUP_DIR=; LIMIT_METHOD=none
  fi
  return 0
}
cgroup_set_percent(){
  local pct="$1" period="$CGROUP_PERIOD_US" n quota
  [[ "$LIMIT_METHOD" == cgroup && -n "$CGROUP_DIR" ]] || return 0
  if (( pct<=0 || pct>=100 )); then quota=max
  else n=$(cores_count); quota=$(awk -v P="$period" -v N="$n" -v R="$pct" 'BEGIN{printf "%.0f", P*N*R/100}'); fi
  printf '%s %s\n' "$quota" "$period" > "$CGROUP_DIR/cpu.max" 2>/dev/null || true
  return 0
}
cpulimit_apply_for_pids(){
  local pct="$1" inc="" pid
  kill_cpulimit_watchers
  command -v cpulimit >/dev/null 2>&1 || return 0
  cpulimit -h 2>&1 | grep -qE -- '-z|children' && inc=-z
  for pid in "${PIDS[@]}"; do
    # 不使用 -b 再次脱离；整个限制器组由主进程负责回收。
    setsid cpulimit -p "$pid" -l "$pct" $inc >/dev/null 2>&1 &
    CPULIMIT_WATCHERS+=("$!")
  done
  return 0
}

calc_cpulimit_per_proc(){ local tp="$1" nc; nc=$(cores_count); local np=${#PIDS[@]}; ((np<1))&&np=1; awk -v tp="$tp" -v nc="$nc" -v np="$np" 'BEGIN{v=tp*nc/np; if(v<1)v=1; if(v>100)v=100; printf "%.0f", v}'; }
limit_apply_percent(){
  local pct="$1"; detect_limit_method
  case "$LIMIT_METHOD" in
    cgroup)  cgroup_set_percent "$pct" ;;
    cpulimit) if (( pct>=100 )); then kill_cpulimit_watchers; else local per; per=$(calc_cpulimit_per_proc "$pct"); cpulimit_apply_for_pids "$per"; fi ;;
    *) : ;; # 静默，不再打印 CPU 能力告警
  esac
  return 0
}
rand_between(){ local min="$1" max="$2"; echo $(( RANDOM % (max - min + 1) + min )); }

normal_usage_tick(){
  (( LIMIT_MODE==2 && $(now_epoch)>=LIMITER_NEXT )) || return 0
  local hour target dur base_min base_max burst_p burst_min burst_max
  LIMITER_CYCLE=$((LIMITER_CYCLE+1))
  hour=$(date +%H)
  if (( 8<=10#$hour && 10#$hour<19 )); then base_min=10; base_max=35; burst_p=20; burst_min=40; burst_max=65
  elif (( 1<=10#$hour && 10#$hour<6 )); then base_min=3; base_max=12; burst_p=5; burst_min=20; burst_max=30
  else base_min=6; base_max=25; burst_p=10; burst_min=30; burst_max=50; fi
  if (( LIMITER_CYCLE % $(rand_between 6 10) == 0 )); then target=$(rand_between 2 5); dur=$(rand_between 5 15)
  elif (( RANDOM%100<burst_p )); then target=$(rand_between "$burst_min" "$burst_max"); dur=$(rand_between 10 45)
  else target=$(rand_between "$base_min" "$base_max"); dur=$(rand_between 30 180); fi
  limit_apply_percent "$target"
  LIMITER_NEXT=$(( $(now_epoch)+dur ))
  return 0
}
start_normal_usage(){ LIMITER_CYCLE=0; LIMITER_NEXT=0; normal_usage_tick; echo "${C_GREEN}[*] 已启用：模拟正常使用。${C_RESET}"; }

stop_normal_usage(){ kill_scheduler; }
limit_set_mode(){
  local mode="$1"; detect_limit_method
  case "$mode" in
    0) LIMIT_MODE=0; stop_normal_usage; kill_cpulimit_watchers; limit_apply_percent 100; echo "${C_GREEN}[+] 已清除 CPU 限制。${C_RESET}" ;;
    1) LIMIT_MODE=1; stop_normal_usage; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; limit_apply_percent 50; echo "${C_GREEN}[+] 已设置恒定 50%。${C_RESET}" ;;
    2) LIMIT_MODE=2; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; start_normal_usage ;;
  esac
}

# 线程

spawn_dl(){ spawn_worker dl "$1"; }
spawn_ul(){ spawn_worker ul "$1"; }

download_worker(){
  local id="$1" sum=0
  while true; do
    (( END_TS>0 && $(date +%s) >= END_TS )) && break
    worker_tick
    local url final limit_bps bytes=0 time_s=0 code="000"
    url="$(pick_active_dl_url)"; final="$(append_nocache "$url" "dl-$id")"; limit_bps=$(calc_dl_thread_bps)
    if (( ALWAYS_CHUNK )); then
      local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
      local r; r=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps"); [[ -n "$r" ]] && bytes="${r%% *}" time_s="${r#* }"
    else
      local r; r="$(curl_measure_full "$final" "$limit_bps")"
      if [[ -n "$r" ]]; then bytes="${r%% *}"; r="${r#* }"; time_s="${r%% *}"; r="${r#* }"; code="${r%% *}"; fi
      if [[ -z "$bytes" || "$bytes" == "0" || ( "$code" != "200" && "$code" != "206" ) ]]; then
        local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
        local r2; r2=$(curl_measure_dl_range "$final" "$range_end" "$limit_bps"); [[ -n "$r2" ]] && bytes="${r2%% *}" time_s="${r2#* }"
      fi
    fi
    transfer_end
    (( bytes>0 )) && mark_url_ok "$url" || mark_url_fail "$url"
    sum=$((sum+bytes)); print_dl_status "$id" "$final" "$bytes" "$sum" "$time_s"
  done
}

upload_worker(){
  local id="$1" sum=0
  while true; do
    (( END_TS>0 && $(date +%s) >= END_TS )) && break
    worker_tick
    local url final limit_bps chunk res bytes=0 code="000" time_s=0
    url="$(pick_active_ul_url)"; final="$(append_nocache "$url" "ul-$id")"; limit_bps=$(calc_ul_thread_bps); chunk=$(( CHUNK_MB_UL*1048576 ))
    res="$(curl_measure_upload "$final" "$chunk" "$limit_bps")"
    if [[ -n "$res" ]]; then bytes="${res%% *}"; res="${res#* }"; time_s="${res%% *}"; res="${res#* }"; code="${res%% *}"; fi
    [[ "$code" =~ ^(200|201|202|204)$ ]] || bytes=0
    transfer_end
    (( bytes>0 )) && mark_url_ok "$url" || mark_url_fail "$url"
    sum=$((sum+bytes)); print_ul_status "$id" "$final" "$bytes" "$sum" "$time_s"
  done
}

# 汇总
bytes_from_file(){ [[ -f "$1" ]] && cat "$1" || echo 0; }
print_summary_once(){ local dl ul; dl=$(bytes_from_file "$DL_TOTAL_FILE"); ul=$(bytes_from_file "$UL_TOTAL_FILE"); echo "${C_BOLD}[Summary ${C_DIM}$(human_now)${C_RESET}${C_BOLD}]${C_RESET} 下载: ${C_CYAN}$(bytes_to_mb "$dl") MB${C_RESET} | 上传: ${C_MAGENTA}$(bytes_to_mb "$ul") MB${C_RESET}"; }

is_summary_running(){ [[ -n "$SUMMARY_PID" ]]; }
start_summary(){ SUMMARY_PID=enabled; SUMMARY_NEXT=$(( $(now_epoch)+SUMMARY_INTERVAL )); return 0; }
stop_summary(){ SUMMARY_PID=; SUMMARY_NEXT=0; return 0; }
summary_tick(){
  if [[ -n "$SUMMARY_PID" ]] && (( SUMMARY_INTERVAL>0 && $(now_epoch)>=SUMMARY_NEXT )); then
    print_summary_once
    SUMMARY_NEXT=$(( $(now_epoch)+SUMMARY_INTERVAL ))
  fi
  return 0
}
# 看门狗必须在主进程运行，重启后的 PID 才能被停止流程准确回收。
watchdog_tick(){
  (( WATCHDOG_ENABLE==1 && $(now_epoch)>=WATCHDOG_NEXT )) || return 0
  local now kind id pid hb busy deadline mt reason restarted=0
  now=$(now_epoch); WATCHDOG_NEXT=$((now+WATCHDOG_INTERVAL))
  for kind in dl ul; do
    local -n workers="${kind^^}_PIDS" restarts="${kind^^}_RESTARTS"
    for id in "${!workers[@]}"; do
      pid=${workers[$id]}; hb="$COUNTER_DIR/hb.$kind.$id"; busy="$COUNTER_DIR/busy.$kind.$id"
      reason=
      if ! kill -0 "$pid" 2>/dev/null; then reason=exited
      elif [[ -r "$busy" ]]; then
        deadline=0; read -r deadline < "$busy" || true
        [[ "$deadline" =~ ^[0-9]+$ ]] && (( now>deadline )) && reason=timeout
      else
        mt=$(stat -c %Y "$hb" 2>/dev/null || echo "$now")
        (( now-mt>WATCHDOG_STALL )) && reason=stalled
      fi
      [[ -n "$reason" ]] || continue
      terminate_group "$pid"; forget_worker "$pid"; unset 'workers[$id]'
      if (( END_TS>0 && now>=END_TS )); then continue; fi
      if (( WATCHDOG_MAX_RESTARTS>0 && ${restarts[$id]:-0}>=WATCHDOG_MAX_RESTARTS )); then continue; fi
      restarts[$id]=$(( ${restarts[$id]:-0}+1 ))
      echo "[WD] $kind#$id $reason; restarting"
      spawn_worker "$kind" "$id"; restarted=1
    done
    unset -n workers restarts
  done
  if (( restarted && LIMIT_MODE==1 )); then limit_apply_percent 50; fi
  if (( restarted && LIMIT_MODE==2 )); then LIMITER_NEXT=0; fi
  return 0
}
controller_tick(){ watchdog_tick; summary_tick; normal_usage_tick; return 0; }

# 启停
init_and_check(){ check_curl || return 1; command -v setsid >/dev/null || { echo "[-] 需要 setsid（util-linux）以安全回收任务"; return 1; }; init_counters; }
wait_first_output(){
  (( START_WAIT_FIRST_OUTPUT )) || return 0
  for ((i=0;i<START_WAIT_SPINS;i++)); do
    [[ -f "$COUNTER_DIR/hb.dl.1" || -f "$COUNTER_DIR/hb.ul.1" ]] && return 0
    sleep 0.1
  done
}
smart_split_threads(){
  local total="$1" extra="ul" dl_pos ul_pos cmp
  if (( total<=1 )); then DL_THREADS=1; UL_THREADS=0; return; fi
  if (( total%2==0 )); then DL_THREADS=$((total/2)); UL_THREADS=$((total/2)); return; fi
  dl_pos=$(awk -v x="$DL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  ul_pos=$(awk -v x="$UL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  if (( dl_pos==1 || ul_pos==1 )); then
    if   (( dl_pos==1 && ul_pos==0 )); then extra="dl"
    elif (( dl_pos==0 && ul_pos==1 )); then extra="ul"
    else cmp=$(awk -v dl="$DL_LIMIT_MB" -v ul="$UL_LIMIT_MB" 'BEGIN{if(dl<ul) print "dl"; else print "ul"}'); extra="$cmp"; fi
  fi
  if [[ "$extra" == "dl" ]]; then DL_THREADS=$(( total/2 + 1 )); UL_THREADS=$(( total - DL_THREADS ))
  else UL_THREADS=$(( total/2 + 1 )); DL_THREADS=$(( total - UL_THREADS )); fi
}

start_consumption(){
  local mode="$1" dn="$2" un="$3"
  (( RUNNING==0 )) || { echo "[-] 请先停止当前任务"; return 1; }
  [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }
  init_and_check || { echo "${C_RED}无法启动：初始化失败。${C_RESET}"; return 1; }
  RUNNING=1; WATCHDOG_NEXT=0
  MODE="$mode"; PIDS=(); DL_PIDS=(); UL_PIDS=(); DL_RESTARTS=(); UL_RESTARTS=(); STOPPED=0
  echo "${C_BOLD}[*] $(human_now) 启动：模式=${MODE}  下载线程=${dn}  上传线程=${un}${C_RESET}"
  echo "${C_BOLD}[*] 作者: ${C_RED}${AUTHOR}${C_RESET} | 探针: ${C_RED}${PROBE_ADDR}${C_RESET}"
  echo "[*] 定时汇总：$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo 每 ${SUMMARY_INTERVAL}s || echo 关闭)"
  (( END_TS>0 )) && echo "[*] 预计停止于：$(date_human_ts "$END_TS")"
  (( LIMIT_MODE>0 )) && { detect_limit_method; [[ "$LIMIT_METHOD" == "cgroup" ]] && cgroup_enter_self; }

  write_runtime_limits
  prepare_worker_script
  if [[ "$MODE" != "u" ]] && (( dn>0 )); then for ((i=1;i<=dn;i++)); do : > "$COUNTER_DIR/hb.dl.$i"; spawn_dl "$i"; sleep 0.05; done; fi
  if [[ "$MODE" != "d" ]] && (( un>0 )); then for ((i=1;i<=un;i++)); do : > "$COUNTER_DIR/hb.ul.$i"; spawn_ul "$i"; sleep 0.05; done; fi

  start_summary
  if (( LIMIT_MODE==1 )); then limit_apply_percent 50; fi
  if (( LIMIT_MODE==2 )); then LIMITER_NEXT=0; normal_usage_tick; fi
  echo "${C_GREEN}[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 可停止。${C_RESET}"
  wait_first_output
  # 注意：此处不再调用 wait/-n，阻塞用 block_loop 实现
}

# 稳定阻塞：只要任一子进程还活着，就一直停留在前台
block_loop(){
  while true; do
    # 若设定了 END_TS，且已到期，主动触发停止
    if (( END_TS>0 && $(date +%s) >= END_TS )); then
      stop_consumption
      break
    fi
    controller_tick
    # 侦测是否还有任何子进程活着
    local alive=0
    for pid in "${PIDS[@]}"; do
      [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null && { alive=1; break; }
    done
    if (( alive==0 )); then stop_consumption; break; fi
    sleep 1
  done
}


stop_consumption(){
  (( STOPPED==0 )) || return 0
  STOPPED=1
  local saved_traps pid dl_g=0 ul_g=0
  saved_traps=$(trap -p INT TERM HUP)
  trap '' INT TERM HUP
  kill_scheduler
  stop_summary
  kill_cpulimit_watchers
  for pid in "${PIDS[@]}"; do terminate_group "$pid"; done
  PIDS=(); DL_PIDS=(); UL_PIDS=()
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  if (( RUNNING )); then
    echo "[*] 最终汇总：下载 $(bytes_to_mb "$dl_g") MB；上传 $(bytes_to_mb "$ul_g") MB"
    echo "[+] 已全部停止。"
  fi
  cleanup_counters
  COUNTER_DIR=; DL_TOTAL_FILE=; UL_TOTAL_FILE=
  if [[ -n "$CGROUP_DIR" ]]; then rmdir -- "$CGROUP_DIR" 2>/dev/null || true; CGROUP_DIR=; fi
  RUNNING=0; WATCHDOG_NEXT=0
  eval "$saved_traps"
  return 0
}

# 交互
list_download_urls(){ echo; echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }
list_upload_urls(){ echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }
parse_choice_to_array(){
  local input="$1" src="$2" dst="$3"; local -n _SRC="$src"; local -n _DST="$dst"; _DST=()
  [[ -z "${input// /}" ]] && { _DST=("${_SRC[@]}"); return; }
  IFS=',' read -r -a idxs <<<"$input"
  for raw in "${idxs[@]}"; do local n="${raw//[[:space:]]/}"; [[ "$n" =~ ^[0-9]+$ ]] || continue; (( n>=1 && n<=${#_SRC[@]} )) || continue; _DST+=("${_SRC[$((n-1))]}"); done
  [[ ${#_DST[@]} -gt 0 ]] || _DST=("${_SRC[@]}")
}

interactive_start(){
  echo; echo "${C_BOLD}请选择消耗模式：${C_RESET}"
  echo "  1) 下载（仅下行）"; echo "  2) 上传（仅上行）"; echo "  3) 同时（上下行）"
  read -rp "模式 [1-3]（默认 3）: " mode_num || true; [[ -z "${mode_num// /}" ]] && mode_num=3
  case "$mode_num" in 1) MODE="d";; 2) MODE="u";; 3) MODE="b";; *) echo "${C_YELLOW}[!] 输入无效，默认同时。${C_RESET}"; MODE="b";; esac

  read -rp "并发线程数（留空自动）: " t || true
  local total_threads
  if [[ -z "${t// /}" ]]; then total_threads=$(auto_threads); echo "[*] 自动选择线程数：$total_threads"
  elif [[ "$t" =~ ^[0-9]+$ ]] && (( t>0 )); then total_threads="$t"
  else echo "${C_YELLOW}[!] 非法输入，使用自动选择。${C_RESET}"; total_threads=$(auto_threads); fi

  if [[ "$MODE" != "u" ]]; then list_download_urls; read -rp "下载地址编号（逗号分隔，留空=全量随机）: " pick_dl || true; parse_choice_to_array "${pick_dl:-}" URLS ACTIVE_URLS; else ACTIVE_URLS=(); fi
  if [[ "$MODE" != "d" ]]; then
    list_upload_urls; read -rp "上传地址编号（逗号分隔，留空=全量随机）: " pick_ul || true
    if [[ -z "${pick_ul// /}" ]]; then ACTIVE_UPLOAD_URLS=( "${UPLOAD_URLS[@]}" ); echo "[*] 未选择编号：默认使用上传地址池全量随机"
    else parse_choice_to_array "${pick_ul:-}" UPLOAD_URLS ACTIVE_UPLOAD_URLS; fi
  else ACTIVE_UPLOAD_URLS=(); fi

  read -rp "运行多久（单位=小时，留空=一直运行）: " hours || true
  if [[ -z "${hours// /}" ]]; then END_TS=0; echo "[*] 将一直运行，直到手动停止。"
  elif [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then local secs; secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}'); END_TS=$(( $(date +%s) + secs )); echo "[*] 预计停止于：$(date_human_ts "$END_TS")"
  else echo "${C_YELLOW}[!] 非法输入，改为一直运行。${C_RESET}"; END_TS=0; fi

  if [[ "$MODE" == "b" ]]; then smart_split_threads "$total_threads"
  elif [[ "$MODE" == "d" ]]; then DL_THREADS="$total_threads"; UL_THREADS=0
  else DL_THREADS=0; UL_THREADS="$total_threads"; fi

  # 启动
  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS" || return 0

  # 开始后前台阻塞（稳定、与 bash <(curl …) 兼容）
  if (( FOLLOW_AFTER_START==1 )); then
    block_loop
    # 通常只有 stop_consumption 后才会从 block_loop 返回
    if (( EXIT_AFTER_STOP==1 )); then exit 0; else return 0; fi
  fi
}

# 限速/CPU 菜单
configure_limits(){
  echo "${C_BOLD}当前限速（总速，MB/s）：DL=${DL_LIMIT_MB}，UL=${UL_LIMIT_MB}${C_RESET}"
  echo "  1) 限制上传总速"; echo "  2) 限制下载总速"; echo "  3) 同时限速"; echo "  4) 清除限速"
  read -rp "选择 [1-4]: " sub || true
  case "${sub:-}" in
    1) read -rp "输入上传总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && { UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 上传总速 = ${UL_LIMIT_MB} MB/s。${C_RESET}"; } || echo "${C_YELLOW}[-] 输入无效。${C_RESET}";;
    2) read -rp "输入下载总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && { DL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 下载总速 = ${DL_LIMIT_MB} MB/s。${C_RESET}"; } || echo "${C_YELLOW}[-] 输入无效。${C_RESET}";;
    3) read -rp "输入上下行总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]] && { echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && { DL_LIMIT_MB="$v"; UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 上下行总速 = ${v} MB/s。${C_RESET}"; } || echo "${C_YELLOW}[-] 输入无效。${C_RESET}";;
    4) DL_LIMIT_MB=0; UL_LIMIT_MB=0; echo "${C_GREEN}[+] 已清除全部限速。${C_RESET}";;
    *) echo "${C_YELLOW}无效选择。${C_RESET}";;
  esac
  write_runtime_limits
}
configure_cpu_limit_mode(){
  echo "${C_BOLD}限制模式（CPU）：${C_RESET}当前 = $(case "$LIMIT_MODE" in 0) echo 关闭;; 1) echo 恒定50%;; 2) echo 模拟正常使用;; esac)"
  echo "  1) 恒定 50%"; echo "  2) 模拟正常使用（随机/突发/夜间低负载）"; echo "  3) 清除限制"
  read -rp "选择 [1-3]: " lm || true
  case "${lm:-}" in 1) limit_set_mode 1 ;; 2) limit_set_mode 2 ;; 3) limit_set_mode 0 ;; *) echo "${C_YELLOW}无效选择，未更改。${C_RESET}" ;; esac
  echo "${C_DIM}说明：优先 cgroup v2；否则退回 cpulimit；模拟模式周期性调整目标负载并穿插短突发与休息窗口。${C_RESET}"
}


# EXIT 覆盖普通退出和 shell 错误；信号只触发一次幂等清理。
exit_cleanup(){
  local code="${1:-0}"
  trap '' INT TERM HUP
  stop_consumption
  exit "$code"
}
install_cleanup_traps(){
  trap 'exit_cleanup 130' INT
  trap 'exit_cleanup 143' TERM
  trap 'exit_cleanup 129' HUP
  trap 'rc=$?; trap - EXIT; set +e; stop_consumption; exit "$rc"' EXIT
}

# 菜单循环
menu(){
  while true; do
    echo
    show_status
    if (( RUNNING )); then
      controller_tick
      if (( END_TS>0 && $(now_epoch)>=END_TS )); then stop_consumption; continue; fi
      c=
      if ! read -r -t 1 c; then
        [[ -t 0 ]] || { stop_consumption; return 0; }
        continue
      fi
    else
      read -rp "${C_BOLD}请选择 [0-6] > ${C_RESET}" c || return 0
    fi
    case "${c:-}" in
      1) interactive_start ;;                         # 开始后阻塞，停止后退出或返回
      2) configure_cpu_limit_mode ;;
      3) stop_consumption; (( EXIT_AFTER_STOP==1 )) && exit 0 ;;
      4) echo; list_download_urls; echo; list_upload_urls ;;
      5) echo "当前定时汇总：$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo \"每 ${SUMMARY_INTERVAL}s\" || echo '关闭')"
         read -rp "输入间隔秒（0=关闭，留空不变）: " v || true
         if [[ -n "${v// /}" && "$v" =~ ^[0-9]+$ ]]; then SUMMARY_INTERVAL="$v"; stop_summary; (( SUMMARY_INTERVAL>0 )) && start_summary; echo "${C_GREEN}[+] 定时汇总已设置为：$([[ $SUMMARY_INTERVAL -gt 0 ]] && echo \"每 ${SUMMARY_INTERVAL}s\" || echo '关闭')${C_RESET}"; else [[ -z "${v// /}" ]] || echo "${C_YELLOW}输入无效。${C_RESET}"; fi ;;
      6) configure_limits ;;
      0) stop_consumption; echo "再见！"; exit 0 ;;
      *) echo "${C_YELLOW}无效选择。${C_RESET}" ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_cleanup_traps
  menu
fi
