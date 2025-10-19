#!/usr/bin/env bash
# 流量消耗/测速脚本（彩色菜单 + 实时统计 + 定时汇总 + 仅脚本限速 + CPU限制
# + 健康检查 + 黏住好链接 + IPv4/IPv6 自动选择 + HTTP/2/HTTP/1 自动选择
# + 单地址预检（下载/上传）：当仅选 1 个地址时，预先展示 v4/v6 连通性、延迟与速度，确认后再执行）
# 更新要点：
# - 下载/上传地址输入支持“编号 或 直接粘贴 URL”（可混填、逗号分隔）
# - 单地址预检：下载单地址必预检；上传若为默认CF地址则跳过预检（否则预检）
# - 其它逻辑维持：自动 v4/v6 + HTTP/2↔1.1 择优、健康检查/拉黑、黏住好链接 等

set -Euo pipefail

#############################
# 可自定义默认值 / 首选项
#############################
DEFAULT_THREADS=${DEFAULT_THREADS:-6}
SUMMARY_INTERVAL=${SUMMARY_INTERVAL:-0}

# IP/HTTP 自动策略
IP_VERSION=${IP_VERSION:-0}            # 4=仅v4, 6=仅v6, 0=自动(v4/v6都通时选更快)
FORCE_HTTP1=${FORCE_HTTP1:-0}          # 1=只用HTTP/1.1；0=自动(HTTP/2与HTTP/1.1都测，选更快)

# 下载/上传模式
ALWAYS_CHUNK=${ALWAYS_CHUNK:-1}        # 1=总是分块；0=先整段→失败再分块
CHUNK_MB_DL=${CHUNK_MB_DL:-50}
CHUNK_MB_UL=${CHUNK_MB_UL:-10}

# “黏住好链接”
STICKY_ENABLE=${STICKY_ENABLE:-1}
STICKY_MIN_MBPS=${STICKY_MIN_MBPS:-5}
STICKY_BAD_ROUNDS=${STICKY_BAD_ROUNDS:-3}
STICKY_GRACE_SEC=${STICKY_GRACE_SEC:-8}

# 健康检查 / 拉黑 / 预检
BLACKLIST_TTL=${BLACKLIST_TTL:-300}          # 秒，默认 5 分钟
PROBE_CONNECT_TIMEOUT=${PROBE_CONNECT_TIMEOUT:-4}
PROBE_MAX_TIME=${PROBE_MAX_TIME:-8}
PROBE_RANGE_MB=${PROBE_RANGE_MB:-1}          # 下载探测块大小(默认 1MB)
PROBE_UPLOAD_KB=${PROBE_UPLOAD_KB:-1024}     # 上传探测块大小(默认 1MB)

# 启动后是否等到第一条线程输出再回到菜单
START_WAIT_FIRST_OUTPUT=${START_WAIT_FIRST_OUTPUT:-1}
START_WAIT_SPINS=${START_WAIT_SPINS:-30}

# 颜色
init_colors(){ if command -v tput >/dev/null 2>&1 && [[ -t 1 ]] && [[ $(tput colors 2>/dev/null||echo 0) -ge 8 ]]; then
  C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_MAGENTA="$(tput setaf 5)"; C_CYAN="$(tput setaf 6)"; C_WHITE="$(tput setaf 7)"
else C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""; fi; }
init_colors

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
UPLOAD_URLS=(
  "https://speed.cloudflare.com/__up"
  "https://httpbin.org/post"
  "https://nghttp2.org/httpbin/post"
  "https://postman-echo.com/post"
)

#############################
# 运行期状态
#############################
PIDS=(); SUMMARY_PID=; END_TS=0
DL_THREADS=0; UL_THREADS=0
ACTIVE_URLS=(); ACTIVE_UPLOAD_URLS=()
MODE=""; COUNTER_DIR=""; DL_TOTAL_FILE=""; UL_TOTAL_FILE=""
DL_LIMIT_MB=0; UL_LIMIT_MB=0

# CPU 限制
LIMIT_MODE=0; LIMIT_METHOD=""; CGROUP_DIR=""; LIMITER_PID=; CPULIMIT_WATCHERS=()

# 黑名单
declare -A BL_DL; declare -A BL_UL

#############################
# 小工具
#############################
human_now(){ date "+%F %T"; }
now_ts(){ date +%s; }
bytes_to_mb(){ awk -v b="$1" 'BEGIN{printf "%.2f", b/1048576}'; }
ms(){ awk -v s="$1" 'BEGIN{printf "%.2f", s*1000}'; }

auto_threads(){
  local cores=1
  if command -v nproc >/dev/null 2>&1; then cores=$(nproc)
  elif [[ -r /proc/cpuinfo ]]; then cores=$(grep -c '^processor' /proc/cpuinfo||echo 1); fi
  local t=$((cores*2)); ((t<4))&&t=4; ((t>32))&&t=32; echo "$t"
}
check_curl(){ command -v curl >/dev/null 2>&1 || { echo "${C_RED}[-] 未检测到 curl，请安装 ca-certificates 与 curl。${C_RESET}"; return 1; }; }
is_running(){ [[ ${#PIDS[@]} -gt 0 ]]; }
is_summary_running(){ [[ -n "${SUMMARY_PID:-}" ]] && kill -0 "$SUMMARY_PID" 2>/dev/null; }

show_urls(){
  echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done
  echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"; i=0; for s in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$s"; done
}

#############################
# 状态面板
#############################
show_status(){
  local dl_g=0 ul_g=0
  [[ -f "$DL_TOTAL_FILE" ]] && dl_g=$(cat "$DL_TOTAL_FILE")
  [[ -f "$UL_TOTAL_FILE" ]] && ul_g=$(cat "$UL_TOTAL_FILE")
  local dl_thr_mb="-" ul_thr_mb="-"
  ((DL_LIMIT_MB>0&&DL_THREADS>0))&&dl_thr_mb=$(awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
  ((UL_LIMIT_MB>0&&UL_THREADS>0))&&ul_thr_mb=$(awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{printf "%.2f", mb/n}')
  echo "${C_BOLD}┌───────────────────────── 状态 ─────────────────────────┐${C_RESET}"
  printf "  运行: %s   模式: %s   线程: DL=%s / UL=%s\n" \
    "$(is_running&&echo "${C_GREEN}运行中${C_RESET}"||echo "${C_YELLOW}未运行${C_RESET}")" \
    "${MODE:-N/A}" "${DL_THREADS:-0}" "${UL_THREADS:-0}"
  printf "  总计: 下载 %s MB / 上传 %s MB\n" "$(bytes_to_mb "$dl_g")" "$(bytes_to_mb "$ul_g")"
  printf "  限速: DL=%s MB/s, UL=%s MB/s; 每线程≈ DL=%s MB/s, UL=%s MB/s\n" \
    "$DL_LIMIT_MB" "$UL_LIMIT_MB" "$dl_thr_mb" "$ul_thr_mb"
  printf "  汇总: %s   结束: %s\n" \
    "$( ((SUMMARY_INTERVAL>0))&&echo "每 ${SUMMARY_INTERVAL}s"||echo "关闭")" \
    "$( ((END_TS>0))&&date -d @"$END_TS" "+%F %T"||echo "手动停止")"
  printf "  限制模式: %s  限制方法: %s\n" \
    "$((LIMIT_MODE==0))&&echo 关闭 || { ((LIMIT_MODE==1))&&echo 恒定50% || echo '5min@90% / 10min@50%'; }" \
    "$([[ -n "$LIMIT_METHOD" ]]&&echo "$LIMIT_METHOD"||echo "-")"
  echo "${C_BOLD}└────────────────────────────────────────────────────────┘${C_RESET}"
}

#############################
# 输入解析：编号 或 直接URL（可混填）
#############################
parse_mixed_selection(){
  local input="$1" src="$2" dst="$3"
  local -n _SRC="$src"; local -n _DST="$dst"; _DST=()
  # 空输入：使用全量源列表
  [[ -z "${input// /}" ]] && { _DST=("${_SRC[@]}"); return; }
  IFS=',' read -r -a items <<<"$input"
  for raw in "${items[@]}"; do
    local tok="${raw#"${raw%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"  # trim
    [[ -z "$tok" ]] && continue
    if [[ "$tok" =~ ^https?:// ]]; then
      _DST+=("$tok")
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      local n="$tok"; (( n>=1 && n<=${#_SRC[@]} )) && _DST+=("${_SRC[$((n-1))]}")
    else
      # 忽略无法识别的 token
      :
    fi
  done
  # 若非空输入但无有效项，回退为全量
  [[ ${#_DST[@]} -gt 0 ]] || _DST=("${_SRC[@]}")
}

#############################
# 统计（临时目录容错）
#############################
init_counters(){
  local bases=(); [[ -n "${TMPDIR:-}" ]] && bases+=("$TMPDIR"); bases+=("/dev/shm" "/var/tmp" "."); COUNTER_DIR=""
  for base in "${bases[@]}"; do
    if [[ -d "$base" && -w "$base" ]]; then COUNTER_DIR="$(mktemp -d -p "$base" vpsburn.XXXXXX 2>/dev/null)"||true; [[ -n "$COUNTER_DIR" ]]&&break; fi
  done
  [[ -n "$COUNTER_DIR" ]] || { echo "${C_RED}[-] 无法创建临时目录。请设置 TMPDIR=/var/tmp 或清理磁盘。${C_RESET}"; return 1; }
  DL_TOTAL_FILE="$COUNTER_DIR/dl.total"; echo 0 > "$DL_TOTAL_FILE" || return 1
  UL_TOTAL_FILE="$COUNTER_DIR/ul.total"; echo 0 > "$UL_TOTAL_FILE" || return 1
}
cleanup_counters(){ [[ -n "$COUNTER_DIR" ]]&&rm -rf "$COUNTER_DIR" 2>/dev/null||true; }

atomic_add(){
  local file="$1" add="$2"
  if command -v flock >/dev/null 2>&1; then
    ( exec 9<>"${file}.lock"; flock -x 9; local cur=0; [[ -f "$file" ]]&&cur=$(cat "$file" 2>/dev/null||echo 0)
      echo $((cur+add)) > "$file"; cat "$file" )
  else
    local cur=0; [[ -f "$file" ]]&&cur=$(cat "$file" 2>/dev/null||echo 0); echo $((cur+add)) > "$file"; cat "$file"
  fi
}

print_dl_status(){ local tid="$1" url="$2" bytes="$3" tsum="$4"; local g; g=$(atomic_add "$DL_TOTAL_FILE" "$bytes")
  [[ -n "$COUNTER_DIR" && ! -f "$COUNTER_DIR/first.tick" ]] && : > "$COUNTER_DIR/first.tick"
  echo "${C_CYAN}[DL#${tid}]${C_RESET} 目标:${C_BLUE}${url}${C_RESET} | 本次:${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程:${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 总:${C_BOLD}$(bytes_to_mb "$g") MB${C_RESET}" ; }
print_ul_status(){ local tid="$1" url="$2" bytes="$3" tsum="$4"; local g; g=$(atomic_add "$UL_TOTAL_FILE" "$bytes")
  [[ -n "$COUNTER_DIR" && ! -f "$COUNTER_DIR/first.tick" ]] && : > "$COUNTER_DIR/first.tick"
  echo "${C_MAGENTA}[UL#${tid}]${C_RESET} 目标:${C_BLUE}${url}${C_RESET} | 本次:${C_YELLOW}$(bytes_to_mb "$bytes") MB${C_RESET} | 线程:${C_GREEN}$(bytes_to_mb "$tsum") MB${C_RESET} | 总:${C_BOLD}$(bytes_to_mb "$g") MB${C_RESET}" ; }

#############################
# 限速
#############################
calc_dl_thread_bps(){ ((DL_LIMIT_MB>0&&DL_THREADS>0)) && awk -v mb="$DL_LIMIT_MB" -v n="$DL_THREADS" 'BEGIN{v=mb*1048576/n;if(v<1)v=1;printf "%.0f",v}' || echo 0; }
calc_ul_thread_bps(){ ((UL_LIMIT_MB>0&&UL_THREADS>0)) && awk -v mb="$UL_LIMIT_MB" -v n="$UL_THREADS" 'BEGIN{v=mb*1048576/n;if(v<1)v=1;printf "%.0f",v}' || echo 0; }

#############################
# curl 选项构建
#############################
_build_ipopt(){ local fam="${1:-0}"; [[ "$fam" == "4" ]]&&echo "-4" || { [[ "$fam" == "6" ]]&&echo "-6" || true; }; }
_build_protoopt(){ local proto="${1:-2}"; [[ "$proto" == "2" ]]&&echo "--http2" || echo "--http1.1"; }

# 下载探测，输出: size time_total http_code http_version time_connect
curl_measure_dl_range(){
  local url="$1" range_end="$2" limit_bps="${3:-0}" fam="${4:-0}" proto="${5:-2}"
  local ipopt=(); local protoopt=(); ipopt+=($(_build_ipopt "$fam")); protoopt+=($(_build_protoopt "$proto"))
  local extra=(); ((limit_bps>0))&&extra+=(--limit-rate "$limit_bps")
  curl -sS -L "${ipopt[@]}" "${protoopt[@]}" \
    --connect-timeout 10 --max-time 300 --retry 2 --retry-all-errors \
    -A "Mozilla/5.0" -H "Range: bytes=0-${range_end}" "${extra[@]}" \
    -w '%{size_download} %{time_total} %{http_code} %{http_version} %{time_connect}' \
    -o /dev/null "$url" 2>/dev/null || true
}
curl_measure_full(){ # url limit_bps fam proto
  local url="$1" limit_bps="${2:-0}" fam="${3:-0}" proto="${4:-2}"
  local ipopt=(); local protoopt=(); ipopt+=($(_build_ipopt "$fam")); protoopt+=($(_build_protoopt "$proto"))
  local extra=(); ((limit_bps>0))&&extra+=(--limit-rate "$limit_bps")
  curl -sS -L "${ipopt[@]}" "${protoopt[@]}" \
    --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 1 --retry-all-errors \
    -A "Mozilla/5.0" "${extra[@]}" \
    -w '%{size_download} %{http_code} %{time_total} %{http_version} %{url_effective}' \
    -o /dev/null "$url" 2>/dev/null || true
}
# 上传探测，输出: size_upload http_code http_version time_total time_connect
curl_measure_upload(){ # url bytes limit_bps fam proto
  local url="$1" bytes="$2" limit_bps="${3:-0}" fam="${4:-0}" proto="${5:-2}"
  local ipopt=(); local protoopt=(); ipopt+=($(_build_ipopt "$fam")); protoopt+=($(_build_protoopt "$proto"))
  local extra=(); ((limit_bps>0))&&extra+=(--limit-rate "$limit_bps")
  head -c "$bytes" /dev/zero | curl -sS -L "${ipopt[@]}" "${protoopt[@]}" \
    --connect-timeout 10 --max-time 600 --retry 2 --retry-all-errors \
    -A "Mozilla/5.0" -H "Content-Type: application/octet-stream" "${extra[@]}" \
    --data-binary @- -w '%{size_upload} %{http_code} %{http_version} %{time_total} %{time_connect}' \
    -o /dev/null -X POST "$url" 2>/dev/null || true
}

#############################
# 健康检查 / 选家族/协议 / 黑名单
#############################
_probe_combo(){ # url fam proto -> print "ok mbps t_total code ver t_conn"
  local url="$1" fam="$2" proto="$3"
  local range_end=$(( PROBE_RANGE_MB*1048576 - 1 )); ((range_end<0))&&range_end=0
  local out; out="$(curl_measure_dl_range "$url" "$range_end" 0 "$fam" "$proto")"
  local size=0 t=0 code=000 ver="0" tconn=0; read -r size t code ver tconn <<<"${out:-"0 0 000 0 0"}"
  local mbps; mbps=$(awk -v b="$size" -v s="$t" 'BEGIN{if(s>0) printf "%.4f", b/1048576/s; else print 0}')
  if [[ "$code" == "200" || "$code" == "206" ]]; then echo "ok $mbps $t $code $ver $tconn"; else echo "bad 0 $t $code $ver $tconn"; fi
}
_probe_combo_ul(){ # url fam proto -> print "ok mbps t_total code ver t_conn"
  local url="$1" fam="$2" proto="$3"
  local bytes=$(( PROBE_UPLOAD_KB*1024 ))
  local out; out="$(curl_measure_upload "$url" "$bytes" 0 "$fam" "$proto")"
  local up=0 code=000 ver="0" tt=0 tc=0; read -r up code ver tt tc <<<"${out:-"0 000 0 0 0"}"
  local mbps; mbps=$(awk -v b="$up" -v s="$tt" 'BEGIN{if(s>0) printf "%.4f", b/1048576/s; else print 0}')
  if [[ "$code" == "200" || "$code" == "204" || "$code" == "201" || "$code" == "202" ]]; then echo "ok $mbps $tt $code $ver $tc"; else echo "bad 0 $tt $code $ver $tc"; fi
}

decide_best_combo_for_url(){ # 下载：echo "fam|proto" or ""
  local url="$1"
  local fams=(); case "$IP_VERSION" in 4) fams=(4) ;; 6) fams=(6) ;; *) fams=(4 6) ;; esac
  local protos=(); (( FORCE_HTTP1 )) && protos=("1.1") || protos=(2 "1.1")
  local best_fam="" best_proto="" best_mbps=0 best_time=999999
  for f in "${fams[@]}"; do
    for p in "${protos[@]}"; do
      local r; r=$(_probe_combo "$url" "$f" "$p"); [[ "$r" =~ ^ok ]] || continue
      local _ok _mbps _t _code _ver _tc; read -r _ok _mbps _t _code _ver _tc <<<"$r"
      if [[ "$p" == "2" && "$_ver" != "2" ]]; then continue; fi
      if [[ "$p" == "1.1" && "$_ver" != "1.1" ]]; then continue; fi
      local better=0 diff; diff=$(awk -v a="$_mbps" -v b="$best_mbps" 'BEGIN{if(b==0)print 1; else if(a>=b*1.05)print 1; else print 0}')
      if (( best_mbps == 0 )) || (( diff == 1 )); then better=1
      else smaller=$(awk -v a="$_t" -v b="$best_time" 'BEGIN{print (a<b)?1:0}'); ((smaller==1)) && better=1; fi
      if (( better==1 )); then best_fam="$f"; best_proto="$p"; best_mbps=${_mbps%.*}.${_mbps#*.}; best_time=${_t%.*}.${_t#*.}; fi
    done
  done
  [[ -n "$best_fam" && -n "$best_proto" ]] && echo "${best_fam}|${best_proto}" || echo ""
}

decide_best_combo_for_url_ul(){ # 上传：echo "fam|proto" or ""
  local url="$1"
  local fams=(); case "$IP_VERSION" in 4) fams=(4) ;; 6) fams=(6) ;; *) fams=(4 6) ;; esac
  local protos=(); (( FORCE_HTTP1 )) && protos=("1.1") || protos=(2 "1.1")
  local best_fam="" best_proto="" best_mbps=0 best_time=999999
  for f in "${fams[@]}"; do
    for p in "${protos[@]}"; do
      local r; r=$(_probe_combo_ul "$url" "$f" "$p"); [[ "$r" =~ ^ok ]] || continue
      local _ok _mbps _t _code _ver _tc; read -r _ok _mbps _t _code _ver _tc <<<"$r"
      if [[ "$p" == "2" && "$_ver" != "2" ]]; then continue; fi
      if [[ "$p" == "1.1" && "$_ver" != "1.1" ]]; then continue; fi
      local better=0 diff; diff=$(awk -v a="$_mbps" -v b="$best_mbps" 'BEGIN{if(b==0)print 1; else if(a>=b*1.05)print 1; else print 0}')
      if (( best_mbps == 0 )) || (( diff == 1 )); then better=1
      else smaller=$(awk -v a="$_t" -v b="$best_time" 'BEGIN{print (a<b)?1:0}'); ((smaller==1)) && better=1; fi
      if (( better==1 )); then best_fam="$f"; best_proto="$p"; best_mbps=${_mbps%.*}.${_mbps#*.}; best_time=${_t%.*}.${_t#*.}; fi
    done
  done
  [[ -n "$best_fam" && -n "$best_proto" ]] && echo "${best_fam}|${best_proto}" || echo ""
}

# —— 单地址预检（下载） —— #
preflight_single_download(){
  local url="$1"
  echo; echo "${C_BOLD}[预检-下载] 单地址连通性/速度测试${C_RESET}"
  echo "目标：${C_BLUE}$url${C_RESET}"
  local fams=(4 6); local protos=(2 "1.1"); (( FORCE_HTTP1 )) && protos=("1.1")
  local v4_ok=0 v6_ok=0 v4_mbps=0 v6_mbps=0 v4_tconn=0 v6_tconn=0 v4_proto="" v6_proto=""
  for f in "${fams[@]}"; do
    local best_m=0 best_t=999999 best_conn=0 best_p=""
    for p in "${protos[@]}"; do
      local r; r=$(_probe_combo "$url" "$f" "$p")
      local status mbps t code ver tconn; read -r status mbps t code ver tconn <<<"$r"
      if [[ "$status" == "ok" ]]; then
        if [[ "$p" == "2" && "$ver" != "2" ]]; then continue; fi
        if [[ "$p" == "1.1" && "$ver" != "1.1" ]]; then continue; fi
        local better=0 diff; diff=$(awk -v a="$mbps" -v b="$best_m" 'BEGIN{if(b==0)print 1; else if(a>=b*1.05)print 1; else print 0}')
        if (( best_m==0 )) || (( diff==1 )); then better=1
        else smaller=$(awk -v a="$t" -v b="$best_t" 'BEGIN{print (a<b)?1:0}'); ((smaller==1)) && better=1; fi
        if (( better==1 )); then best_m="$mbps"; best_t="$t"; best_conn="$tconn"; best_p="$p"; fi
      fi
    done
    if (( f==4 )); then (( $(awk -v x="$best_m" 'BEGIN{print (x>0)?1:0}') )) && v4_ok=1
      v4_mbps="$best_m"; v4_tconn="$best_conn"; v4_proto="$best_p"
    else (( $(awk -v x="$best_m" 'BEGIN{print (x>0)?1:0}') )) && v6_ok=1
      v6_mbps="$best_m"; v6_tconn="$best_conn"; v6_proto="$best_p"
    fi
  done
  if (( v4_ok )); then
    echo "IPv4：${C_GREEN}可用${C_RESET}  延迟: $(ms "$v4_tconn") ms  速度: $(printf '%.2f' "$v4_mbps") MB/s  协议: HTTP/${v4_proto}"
  else echo "IPv4：${C_RED}不可用${C_RESET}"; fi
  if (( v6_ok )); then
    echo "IPv6：${C_GREEN}可用${C_RESET}  延迟: $(ms "$v6_tconn") ms  速度: $(printf '%.2f' "$v6_mbps") MB/s  协议: HTTP/${v6_proto}"
  else echo "IPv6：${C_RED}不可用${C_RESET}"; fi

  local chosen_fam="" chosen_proto="" chosen_desc=""
  if (( v4_ok==0 && v6_ok==0 )); then echo "${C_RED}[!] v4/v6 都不可用，取消启动。${C_RESET}"; return 2
  elif (( v4_ok==1 && v6_ok==0 )); then chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"
  elif (( v4_ok==0 && v6_ok==1 )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
  else
    local pick_v6; pick_v6=$(awk -v a="$v6_mbps" -v b="$v4_mbps" 'BEGIN{print (a>=b*1.05)?1:0}')
    if (( pick_v6==1 )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
    else
      local near; near=$(awk -v a="$v6_mbps" -v b="$v4_mbps" 'BEGIN{if(b==0)print 0; else print (a>=b*0.95 && a<=b*1.05)?1:0}')
      if (( near==1 )); then
        local v6_conn_ms; v6_conn_ms=$(ms "$v6_tconn"); local v4_conn_ms; v4_conn_ms=$(ms "$v4_tconn")
        if (( $(awk -v a="$v6_conn_ms" -v b="$v4_conn_ms" 'BEGIN{print (a<b)?1:0}') )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
        else chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"; fi
      else chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"
      fi
    fi
  fi
  echo "${C_CYAN}将使用（下载）：${chosen_desc}${C_RESET}"
  read -rp "确认开始下载（回车继续 / 输入 n 取消）: " _ok || true
  [[ "${_ok:-}" == "n" || "${_ok:-}" == "N" ]] && return 1
  return 0
}

# —— 单地址预检（上传） —— #
preflight_single_upload(){
  local url="$1"
  echo; echo "${C_BOLD}[预检-上传] 单地址连通性/速度测试${C_RESET}"
  echo "目标：${C_BLUE}$url${C_RESET}"
  local fams=(4 6); local protos=(2 "1.1"); (( FORCE_HTTP1 )) && protos=("1.1")
  local v4_ok=0 v6_ok=0 v4_mbps=0 v6_mbps=0 v4_tconn=0 v6_tconn=0 v4_proto="" v6_proto=""
  for f in "${fams[@]}"; do
    local best_m=0 best_t=999999 best_conn=0 best_p=""
    for p in "${protos[@]}"; do
      local r; r=$(_probe_combo_ul "$url" "$f" "$p")
      local status mbps t code ver tconn; read -r status mbps t code ver tconn <<<"$r"
      if [[ "$status" == "ok" ]]; then
        if [[ "$p" == "2" && "$ver" != "2" ]]; then continue; fi
        if [[ "$p" == "1.1" && "$ver" != "1.1" ]]; then continue; fi
        local better=0 diff; diff=$(awk -v a="$mbps" -v b="$best_m" 'BEGIN{if(b==0)print 1; else if(a>=b*1.05)print 1; else print 0}')
        if (( best_m==0 )) || (( diff==1 )); then better=1
        else smaller=$(awk -v a="$t" -v b="$best_t" 'BEGIN{print (a<b)?1:0}'); ((smaller==1)) && better=1; fi
        if (( better==1 )); then best_m="$mbps"; best_t="$t"; best_conn="$tconn"; best_p="$p"; fi
      fi
    done
    if (( f==4 )); then (( $(awk -v x="$best_m" 'BEGIN{print (x>0)?1:0}') )) && v4_ok=1
      v4_mbps="$best_m"; v4_tconn="$best_conn"; v4_proto="$best_p"
    else (( $(awk -v x="$best_m" 'BEGIN{print (x>0)?1:0}') )) && v6_ok=1
      v6_mbps="$best_m"; v6_tconn="$best_conn"; v6_proto="$best_p"
    fi
  done
  if (( v4_ok )); then
    echo "IPv4：${C_GREEN}可用${C_RESET}  首连: $(ms "$v4_tconn") ms  上传速: $(printf '%.2f' "$v4_mbps") MB/s  协议: HTTP/${v4_proto}"
  else echo "IPv4：${C_RED}不可用${C_RESET}"; fi
  if (( v6_ok )); then
    echo "IPv6：${C_GREEN}可用${C_RESET}  首连: $(ms "$v6_tconn") ms  上传速: $(printf '%.2f' "$v6_mbps") MB/s  协议: HTTP/${v6_proto}"
  else echo "IPv6：${C_RED}不可用${C_RESET}"; fi

  local chosen_fam="" chosen_proto="" chosen_desc=""
  if (( v4_ok==0 && v6_ok==0 )); then echo "${C_RED}[!] v4/v6 都不可用，取消启动。${C_RESET}"; return 2
  elif (( v4_ok==1 && v6_ok==0 )); then chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"
  elif (( v4_ok==0 && v6_ok==1 )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
  else
    local pick_v6; pick_v6=$(awk -v a="$v6_mbps" -v b="$v4_mbps" 'BEGIN{print (a>=b*1.05)?1:0}')
    if (( pick_v6==1 )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
    else
      local near; near=$(awk -v a="$v6_mbps" -v b="$v4_mbps" 'BEGIN{if(b==0)print 0; else print (a>=b*0.95 && a<=b*1.05)?1:0}')
      if (( near==1 )); then
        local v6_conn_ms; v6_conn_ms=$(ms "$v6_tconn"); local v4_conn_ms; v4_conn_ms=$(ms "$v4_tconn")
        if (( $(awk -v a="$v6_conn_ms" -v b="$v4_conn_ms" 'BEGIN{print (a<b)?1:0}') )); then chosen_fam=6; chosen_proto="$v6_proto"; chosen_desc="IPv6 / HTTP/$v6_proto"
        else chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"; fi
      else chosen_fam=4; chosen_proto="$v4_proto"; chosen_desc="IPv4 / HTTP/$v4_proto"
      fi
    fi
  fi
  echo "${C_CYAN}将使用（上传）：${chosen_desc}${C_RESET}"
  read -rp "确认开始上传（回车继续 / 输入 n 取消）: " _ok || true
  [[ "${_ok:-}" == "n" || "${_ok:-}" == "N" ]] && return 1
  return 0
}

# 黑名单/选择
is_blacklisted_dl(){ local until="${BL_DL[$1]:-0}"; (( until>0 && $(now_ts) < until )); }
is_blacklisted_ul(){ local until="${BL_UL[$1]:-0}"; (( until>0 && $(now_ts) < until )); }
blacklist_dl(){ BL_DL["$1"]=$(( $(now_ts) + BLACKLIST_TTL )); }
blacklist_ul(){ BL_UL["$1"]=$(( $(now_ts) + BLACKLIST_TTL )); }

pick_working_dl(){ # -> "url|fam|proto"
  local tries=${#ACTIVE_URLS[@]}; ((tries==0))&&{ echo ""; return 1; }
  local i=0
  while (( i<tries )); do
    local cand="${ACTIVE_URLS[RANDOM % ${#ACTIVE_URLS[@]}]}"
    is_blacklisted_dl "$cand" && { ((i++)); continue; }
    local choice; choice="$(decide_best_combo_for_url "$cand")"
    if [[ -z "$choice" ]]; then blacklist_dl "$cand"; ((i++)); continue; fi
    echo "${cand}|${choice}"; return 0
  done
  echo ""; return 1
}

pick_working_ul(){ # -> "url|fam|proto"（基于上传探测）
  local tries=${#ACTIVE_UPLOAD_URLS[@]}; ((tries==0))&&{ echo ""; return 1; }
  local i=0
  while (( i<tries )); do
    local cand="${ACTIVE_UPLOAD_URLS[RANDOM % ${#ACTIVE_UPLOAD_URLS[@]}]}"
    is_blacklisted_ul "$cand" && { ((i++)); continue; }
    local choice; choice="$(decide_best_combo_for_url_ul "$cand")"
    if [[ -z "$choice" ]]; then blacklist_ul "$cand"; ((i++)); continue; fi
    echo "${cand}|${choice}"; return 0
  done
  echo ""; return 1
}

#############################
# 工作线程（下载：黏住好链接 + 健康检查）
#############################
calc_thr_limit_mbps(){ local l="$1"; awk -v L="$l" 'BEGIN{if(L>0) printf "%.2f", L/1048576*0.7; else print 0}'; }

download_worker(){
  local id="$1"; local thread_sum=0
  local sticky_url=""; local sticky_family="0"; local sticky_proto="2"; local bad_rounds=0

  while true; do
    (( END_TS>0 )) && (( $(date +%s) >= END_TS )) && break

    if [[ -z "$sticky_url" ]]; then
      local pair; pair=$(pick_working_dl); if [[ -z "$pair" ]]; then sleep 3; continue; fi
      sticky_url="${pair%|*}"; local rest="${pair#*|}"; sticky_family="${rest%|*}"; sticky_proto="${rest#*|}"
    fi

    local final="${sticky_url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_dl_thread_bps)

    local bytes=0 secs=0 code="000" ver="0" res
    if (( ALWAYS_CHUNK )); then
      local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
      res="$(curl_measure_dl_range "$final" "$range_end" "$limit_bps" "$sticky_family" "$sticky_proto")"
      read -r bytes secs code ver _tc <<<"${res:-"0 0 000 0 0"}"
    else
      res="$(curl_measure_full "$final" "$limit_bps" "$sticky_family" "$sticky_proto")"
      if [[ -n "$res" ]]; then
        bytes="${res%% *}"; res="${res#* }"; code="${res%% *}"; res="${res#* }"; secs="${res%% *}"; res="${res#* }"; ver="${res%% *}"
      fi
      if [[ -z "$bytes" || "$bytes" == "0" || ( "$code" != "200" && "$code" != "206" ) ]]; then
        local range_end=$(( CHUNK_MB_DL*1048576 - 1 ))
        res="$(curl_measure_dl_range "$final" "$range_end" "$limit_bps" "$sticky_family" "$sticky_proto")"
        read -r bytes secs code ver _tc <<<"${res:-"0 0 000 0 0"}"
      fi
    fi

    local thr_limit_mbps; thr_limit_mbps=$(calc_thr_limit_mbps "$limit_bps")
    local need_mbps; need_mbps=$(awk -v base="$STICKY_MIN_MBPS" -v lim="$thr_limit_mbps" 'BEGIN{if(lim>0&&lim<base) printf "%.2f", lim; else printf "%.2f", base}')
    local speed_mbps; speed_mbps=$(awk -v b="$bytes" -v s="$secs" 'BEGIN{if(s>0) printf "%.2f", b/1048576/s; else print 0}')
    local verdict; verdict=$(awk -v s="$speed_mbps" -v need="$need_mbps" -v sec="$secs" -v grace="$STICKY_GRACE_SEC" 'BEGIN{
      if (sec<grace && sec>0) print "neutral"; else if (s>=need && s>0) print "good"; else print "bad"; }')

    if (( STICKY_ENABLE )); then
      case "$verdict" in
        good) bad_rounds=0 ;;
        neutral) : ;;
        bad)
          bad_rounds=$((bad_rounds+1))
          if (( bad_rounds >= STICKY_BAD_ROUNDS )); then
            blacklist_dl "$sticky_url"; sticky_url=""; sticky_family="0"; sticky_proto="2"; bad_rounds=0
          fi
          ;;
      esac
    fi

    thread_sum=$((thread_sum + bytes))
    print_dl_status "$id" "$final" "$bytes" "$thread_sum"
  done
}

#############################
# 工作线程（上传：健康检查 + 自适应家族/协议）
#############################
upload_worker(){
  local id="$1"; local thread_sum=0
  while true; do
    (( END_TS>0 )) && (( $(date +%s) >= END_TS )) && break
    local pair; pair=$(pick_working_ul); if [[ -z "$pair" ]]; then sleep 3; continue; fi
    local url="${pair%|*}"; local rest="${pair#*|}"; local fam="${rest%|*}"; local proto="${rest#*|}"
    local final="${url}?nocache=$(date +%s%N)-$id-$RANDOM"
    local limit_bps; limit_bps=$(calc_ul_thread_bps)
    local chunk_bytes=$(( CHUNK_MB_UL*1048576 ))
    local res; res="$(curl_measure_upload "$final" "$chunk_bytes" "$limit_bps" "$fam" "$proto")"
    local bytes=0 code="000" ver="0" tt=0 tc=0
    [[ -n "$res" ]] && { read -r bytes code ver tt tc <<<"$res"; }
    if [[ "$code" != "200" && "$code" != "204" && "$code" != "201" && "$code" != "202" ]]; then
      bytes=0; blacklist_ul "$url"; sleep 1
    fi
    thread_sum=$((thread_sum + bytes))
    print_ul_status "$id" "$final" "$bytes" "$thread_sum"
  done
}

#############################
# 定时汇总
#############################
bytes_from_file(){ [[ -f "$1" ]] && cat "$1" || echo 0; }
print_summary_once(){ local dl ul; dl=$(bytes_from_file "$DL_TOTAL_FILE"); ul=$(bytes_from_file "$UL_TOTAL_FILE")
  echo "${C_BOLD}[Summary ${C_DIM}$(human_now)${C_RESET}${C_BOLD}]${C_RESET} 下载: ${C_CYAN}$(bytes_to_mb "$dl") MB${C_RESET} | 上传: ${C_MAGENTA}$(bytes_to_mb "$ul") MB${C_RESET}"; }
summary_worker(){ while true; do sleep "$SUMMARY_INTERVAL"; print_summary_once; done; }
start_summary(){ ((SUMMARY_INTERVAL>0)) && { is_summary_running && echo "${C_YELLOW}[*] 定时汇总已在运行。${C_RESET}" || { summary_worker & SUMMARY_PID=$!; echo "${C_GREEN}[*] 已开启定时汇总，每 ${SUMMARY_INTERVAL}s。${C_RESET}"; }; }; }
stop_summary(){ is_summary_running && { kill -TERM "$SUMMARY_PID" 2>/dev/null||true; wait "$SUMMARY_PID" 2>/dev/null||true; SUMMARY_PID=; echo "${C_GREEN}[+] 已停止定时汇总。${C_RESET}"; }; }

#############################
# 清理
#############################
kill_tree_once(){ local sig="$1"; if [[ ${#PIDS[@]} -gt 0 ]]; then for pid in "${PIDS[@]}"; do pkill -"${sig}" -P "$pid" 2>/dev/null||true; kill -"${sig}" "$pid" 2>/dev/null||true; done; fi; }

#############################
# CPU 限制（cgroup/cpulimit）
#############################
cores_count(){ command -v nproc >/dev/null 2>&1 && nproc || echo 1; }
detect_limit_method(){ if [[ -z "$LIMIT_METHOD" ]]; then
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qw cpu /sys/fs/cgroup/cgroup.controllers && [[ -w /sys/fs/cgroup ]]; then LIMIT_METHOD="cgroup";
  elif command -v cpulimit >/dev/null 2>&1; then LIMIT_METHOD="cpulimit"; else LIMIT_METHOD="none"; fi; fi; }
is_scheduler_running(){ [[ -n "${LIMITER_PID:-}" ]] && kill -0 "$LIMITER_PID" 2>/dev/null; }
kill_scheduler(){ is_scheduler_running && { kill -TERM "$LIMITER_PID" 2>/dev/null||true; wait "$LIMITER_PID" 2>/dev/null||true; LIMITER_PID=; }; }
kill_cpulimit_watchers(){ if ((${#CPULIMIT_WATCHERS[@]})); then for wp in "${CPULIMIT_WATCHERS[@]}"; do kill -TERM "$wp" 2>/dev/null||true; done; CPULIMIT_WATCHERS=(); fi; }
cgroup_enter_self(){ set +e; [[ "$LIMIT_METHOD" != "cgroup" ]]&&{ set -e; return 0; }; [[ -z "$CGROUP_DIR" ]]&&{ CGROUP_DIR="/sys/fs/cgroup/vpsburn.$$"; mkdir -p "$CGROUP_DIR" 2>/dev/null||true; }
  [[ -w "$CGROUP_DIR/cgroup.procs" ]]&&echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null||true; set -e; }
cgroup_set_percent(){ set +e; local pct="$1"; [[ "$LIMIT_METHOD" != "cgroup" ]]&&{ set -e; return 0; }; [[ -z "$CGROUP_DIR" ]]&&{ set -e; return 0; }
  local period=100000; if ((pct<=0||pct>=100)); then echo "max" > "$CGROUP_DIR/cpu.max" 2>/dev/null||true; set -e; return 0; fi
  local n; n=$(cores_count); local quota; quota=$(awk -v P="$period" -v N="$n" -v R="$pct" 'BEGIN{printf "%.0f", P*N*R/100}')
  echo "$quota $period" > "$CGROUP_DIR/cpu.max" 2>/dev/null||true; set -e; }
cpulimit_apply_for_pids(){ local pct="$1"; kill_cpulimit_watchers; command -v cpulimit >/dev/null 2>&1||return 0; ((${#PIDS[@]}==0))&&return 0
  for pid in "${PIDS[@]}"; do cpulimit -p "$pid" -l "$pct" -b >/dev/null 2>&1 & CPULIMIT_WATCHERS+=("$!"); done; }
limit_apply_percent(){ set +e; local pct="$1"; detect_limit_method
  case "$LIMIT_METHOD" in cgroup) cgroup_set_percent "$pct" ;;
    cpulimit) ((pct>=100))&&kill_cpulimit_watchers || cpulimit_apply_for_pids "$pct" ;;
    *) echo "${C_YELLOW}[!] 无 cgroup 写权限且未安装 cpulimit，无法精确限速。${C_RESET}" ;; esac; set -e; }
limit_scheduler(){ while true; do limit_apply_percent 90; sleep 300; limit_apply_percent 50; sleep 600; done; }
start_limit_scheduler(){ is_scheduler_running || { limit_scheduler & LIMITER_PID=$!; echo "${C_GREEN}[*] 周期限速已启用。${C_RESET}"; }; }
stop_limit_scheduler(){ kill_scheduler; }
limit_set_mode(){ set +e; local mode="$1"; detect_limit_method
  case "$mode" in
    0) LIMIT_MODE=0; stop_limit_scheduler; kill_cpulimit_watchers; limit_apply_percent 100; echo "${C_GREEN}[+] 已清除 CPU 限制。${C_RESET}" ;;
    1) LIMIT_MODE=1; stop_limit_scheduler; [[ "$LIMIT_METHOD" == "cgroup" ]]&&cgroup_enter_self; limit_apply_percent 50; echo "${C_GREEN}[+] 已设置恒定 50% CPU 限制。${C_RESET}" ;;
    2) LIMIT_MODE=2; [[ "$LIMIT_METHOD" == "cgroup" ]]&&cgroup_enter_self; start_limit_scheduler ;;
  esac; set -e; }
ensure_limit_on_current_run(){ ((LIMIT_MODE==0))&&return 0; detect_limit_method
  if [[ "$LIMIT_METHOD" == "cgroup" ]]; then ((LIMIT_MODE==1))&&limit_apply_percent 50; ((LIMIT_MODE==2))&&start_limit_scheduler
  elif [[ "$LIMIT_METHOD" == "cpulimit" ]]; then ((LIMIT_MODE==1))&&cpulimit_apply_for_pids 50; ((LIMIT_MODE==2))&&start_limit_scheduler; fi; }

#############################
# 启停控制 & 智能分配
#############################
init_and_check(){ check_curl || return 1; init_counters; }
wait_first_output(){ ((START_WAIT_FIRST_OUTPUT))||return 0; for ((i=0;i<START_WAIT_SPINS;i++)); do [[ -f "$COUNTER_DIR/first.tick" ]]&&return 0; sleep 0.1; done; }
smart_split_threads(){
  local total="$1"; if ((total<=1)); then DL_THREADS=1; UL_THREADS=0; return; fi
  if ((total%2==0)); then DL_THREADS=$((total/2)); UL_THREADS=$((total/2)); return; fi
  local extra="ul"; local dl_pos=$(awk -v x="$DL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}'); local ul_pos=$(awk -v x="$UL_LIMIT_MB" 'BEGIN{print (x>0)?1:0}')
  if ((dl_pos==1||ul_pos==1)); then
    if   ((dl_pos==1&&ul_pos==0)); then extra="dl"
    elif ((dl_pos==0&&ul_pos==1)); then extra="ul"
    else extra=$(awk -v dl="$DL_LIMIT_MB" -v ul="$UL_LIMIT_MB" 'BEGIN{if(dl<ul)print "dl";else print "ul"}'); fi
  fi
  if [[ "$extra" == "dl" ]]; then DL_THREADS=$((total/2+1)); UL_THREADS=$((total-DL_THREADS)); else UL_THREADS=$((total/2+1)); DL_THREADS=$((total-UL_THREADS)); fi
}

start_consumption(){
  local mode="$1" dl_n="$2" ul_n="$3"; [[ "$mode" =~ ^(d|u|b)$ ]] || { echo "[-] 内部错误：mode 无效"; return 1; }
  init_and_check || { echo "${C_RED}无法启动：初始化失败（可能无空间或未安装 curl）。${C_RESET}"; return 1; }
  MODE="$mode"; PIDS=()
  echo "${C_BOLD}[*] $(human_now) 启动：模式=${MODE}  下载线程=${dl_n}  上传线程=${ul_n}${C_RESET}"
  echo "[*] 定时汇总：$( ((SUMMARY_INTERVAL>0))&&echo "每 ${SUMMARY_INTERVAL}s"||echo "关闭" )"
  ((END_TS>0))&&echo "[*] 预计结束于：$(date -d @"$END_TS" "+%F %T")"
  ((LIMIT_MODE>0))&&{ detect_limit_method; [[ "$LIMIT_METHOD" == "cgroup" ]]&&cgroup_enter_self; }
  if [[ "$MODE" != "u" ]] && (( dl_n>0 )); then for ((i=1;i<=dl_n;i++)); do download_worker "$i" & PIDS+=("$!"); sleep 0.05; done; fi
  if [[ "$MODE" != "d" ]] && (( ul_n>0 )); then for ((i=1;i<=ul_n;i++)); do upload_worker "$i" & PIDS+=("$!"); sleep 0.05; done; fi
  start_summary; echo "${C_GREEN}[+] 全部线程已启动（共 ${#PIDS[@]}）。按 Ctrl+C 或选菜单 3 停止。${C_RESET}"
  wait_first_output; ensure_limit_on_current_run
}

stop_consumption(){
  if ! is_running; then echo "${C_YELLOW}[*] 当前没有运行中的线程。${C_RESET}"
  else
    echo "${C_BOLD}[*] $(human_now) 正在停止全部线程…${C_RESET}"
    kill_tree_once INT; sleep 0.5; kill_tree_once TERM; sleep 0.5; kill_tree_once KILL
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null||true; pkill -KILL -P "$pid" 2>/dev/null||true; done
    PIDS=()
  fi
  kill_cpulimit_watchers; stop_summary
  local dl_g=0 ul_g=0; [[ -f "$DL_TOTAL_FILE" ]]&&dl_g=$(cat "$DL_TOTAL_FILE"); [[ -f "$UL_TOTAL_FILE" ]]&&ul_g=$(cat "$UL_TOTAL_FILE")
  echo "${C_BOLD}[*] 最终汇总：下载 ${C_CYAN}$(bytes_to_mb "$dl_g") MB${C_RESET}；上传 ${C_MAGENTA}$(bytes_to_mb "$ul_g") MB${C_RESET}"
  cleanup_counters; echo "${C_GREEN}[+] 已全部停止。${C_RESET}"
}

#############################
# 交互
#############################
list_download_urls(){ echo; echo "${C_BOLD}下载地址（共 ${#URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }
list_upload_urls(){ echo; echo "${C_BOLD}上传地址（共 ${#UPLOAD_URLS[@]} 个）：${C_RESET}"; local i=0; for u in "${UPLOAD_URLS[@]}"; do printf "  %2d) %s\n" "$((++i))" "$u"; done; }

interactive_start(){
  echo; echo "${C_BOLD}请选择消耗模式：${C_RESET}"; echo "  1) 下载"; echo "  2) 上传"; echo "  3) 同时"
  read -rp "模式 [1-3]（默认 3）: " mode_num || true; [[ -z "${mode_num// /}" ]]&&mode_num=3
  case "$mode_num" in 1) MODE="d" ;; 2) MODE="u" ;; 3) MODE="b" ;; *) echo "${C_YELLOW}[!] 输入无效，使用默认：同时。${C_RESET}"; MODE="b" ;; esac

  read -rp "并发线程数（留空自动）: " t || true; local total_threads
  if [[ -z "${t// /}" ]]; then total_threads=$(auto_threads); echo "[*] 自动选择线程数：$total_threads"
  elif [[ "$t" =~ ^[0-9]+$ ]] && (( t>0 )); then total_threads="$t"
  else echo "${C_YELLOW}[!] 非法输入，使用自动选择。${C_RESET}"; total_threads=$(auto_threads); fi

  if [[ "$MODE" != "u" ]]; then
    list_download_urls
    read -rp "下载地址（输入 编号或URL，可混填，逗号分隔；留空=全量）: " pick_dl || true
    parse_mixed_selection "${pick_dl:-}" URLS ACTIVE_URLS
  else
    ACTIVE_URLS=()
  fi

  if [[ "$MODE" != "d" ]]; then
    list_upload_urls
    read -rp "上传地址（输入 编号或URL，可混填，逗号分隔；留空=仅 Cloudflare）: " pick_ul || true
    if [[ -z "${pick_ul// /}" ]]; then
      ACTIVE_UPLOAD_URLS=( "${UPLOAD_URLS[0]}" )
      echo "[*] 默认仅使用 ${UPLOAD_URLS[0]}"
    else
      parse_mixed_selection "${pick_ul:-}" UPLOAD_URLS ACTIVE_UPLOAD_URLS
    fi
  else
    ACTIVE_UPLOAD_URLS=()
  fi

  # —— 单地址预检（下载/上传各自恰好 1 个时触发）——
  if [[ "$MODE" != "u" ]] && (( ${#ACTIVE_URLS[@]} == 1 )); then
    preflight_single_download "${ACTIVE_URLS[0]}" || { [[ $? -eq 2 ]] && echo "${C_YELLOW}建议：更换下载地址或稍后再试。${C_RESET}"; return; }
  fi
  if [[ "$MODE" != "d" ]] && (( ${#ACTIVE_UPLOAD_URLS[@]} == 1 )); then
    # 如果是默认CF上传地址，则跳过预检
    if [[ "${ACTIVE_UPLOAD_URLS[0]}" != "${UPLOAD_URLS[0]}" ]]; then
      preflight_single_upload "${ACTIVE_UPLOAD_URLS[0]}" || { [[ $? -eq 2 ]] && echo "${C_YELLOW}建议：更换上传地址或稍后再试。${C_RESET}"; return; }
    fi
  fi

  read -rp "运行多久（小时，留空=一直）: " hours || true
  if [[ -z "${hours// /}" ]]; then END_TS=0; echo "[*] 将一直运行，直到手动停止。"
  elif [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then local secs; secs=$(awk -v h="$hours" 'BEGIN{printf "%.0f", h*3600}'); END_TS=$(( $(date +%s) + secs )); echo "[*] 预计至 $(date -d @"$END_TS" "+%F %T") 停止。"
  else echo "${C_YELLOW}[!] 非法输入，改为一直运行。${C_RESET}"; END_TS=0; fi

  if [[ "$MODE" == "b" ]]; then smart_split_threads "$total_threads"
  elif [[ "$MODE" == "d" ]]; then DL_THREADS="$total_threads"; UL_THREADS=0
  else DL_THREADS=0; UL_THREADS="$total_threads"; fi

  start_consumption "$MODE" "$DL_THREADS" "$UL_THREADS"
}

configure_summary(){
  echo "当前定时汇总：$( ((SUMMARY_INTERVAL>0))&&echo "每 ${SUMMARY_INTERVAL}s"||echo "关闭" )"
  read -rp "输入 N（秒）：N>0 开启/修改；0 关闭；回车取消: " n || true
  [[ -z "${n// /}" ]]&&{ echo "未更改。"; return; }
  if [[ "$n" =~ ^[0-9]+$ ]]; then SUMMARY_INTERVAL="$n"; if ((SUMMARY_INTERVAL==0)); then stop_summary; echo "${C_GREEN}[+] 已关闭定时汇总。${C_RESET}"
    else echo "${C_GREEN}[+] 设置为每 ${SUMMARY_INTERVAL}s 汇总。${C_RESET}"; is_summary_running&&stop_summary; is_running&&start_summary; fi
  else echo "${C_YELLOW}[-] 输入无效，未更改。${C_RESET}"; fi
}

configure_limits(){
  echo "${C_BOLD}当前限速：DL=${DL_LIMIT_MB} MB/s，UL=${UL_LIMIT_MB} MB/s${C_RESET}"
  echo "  1) 限制上传速度"; echo "  2) 限制下载速度"; echo "  3) 同时限速"; echo "  4) 清除全部限速"
  read -rp "选择 [1-4]: " sub || true
  case "${sub:-}" in
    1) read -rp "输入上传总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]]&&{ echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]&&{ UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已设置上传 ${UL_LIMIT_MB} MB/s。${C_RESET}"; }||echo "${C_YELLOW}[-] 无效。${C_RESET}" ;;
    2) read -rp "输入下载总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]]&&{ echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]&&{ DL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已设置下载 ${DL_LIMIT_MB} MB/s。${C_RESET}"; }||echo "${C_YELLOW}[-] 无效。${C_RESET}" ;;
    3) read -rp "输入上下行总速（MB/s，0 取消）: " v || true; [[ -z "${v// /}" ]]&&{ echo "未更改。"; return; }; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]&&{ DL_LIMIT_MB="$v"; UL_LIMIT_MB="$v"; echo "${C_GREEN}[+] 已设置 ${v} MB/s。${C_RESET}"; }||echo "${C_YELLOW}[-] 无效。${C_RESET}" ;;
    4) DL_LIMIT_MB=0; UL_LIMIT_MB=0; echo "${C_GREEN}[+] 已清除全部限速。${C_RESET}";;
    *) echo "${C_YELLOW}无效选择。${C_RESET}";;
  esac
}

configure_cpu_limit_mode(){
  echo "${C_BOLD}限制模式：${C_RESET}当前 = $(
    case "$LIMIT_MODE" in 0) echo "关闭" ;; 1) echo "恒定50%" ;; 2) echo "5min@90% / 10min@50%" ;; esac
  )"
  echo "  1) 限制到 50%"; echo "  2) 5 分钟 90%，10 分钟 50%，循环"; echo "  3) 清除限制"
  read -rp "选择 [1-3]: " lm || true
  case "${lm:-}" in 1) limit_set_mode 1 ;; 2) limit_set_mode 2 ;; 3) limit_set_mode 0 ;; *) echo "${C_YELLOW}无效选择，未更改。${C_RESET}" ;; esac
  echo "${C_DIM}说明：优先用 cgroup v2，其次 cpulimit；均不可用时仅提示无法精确限速。${C_RESET}"
}

#############################
# Trap / 菜单
#############################
trap 'echo; echo "${C_YELLOW}[!] 捕获到信号，正在清理…${C_RESET}"; stop_consumption; exit 0' INT TERM

menu(){
  while true; do
    echo; echo "${C_BOLD}┌────────────────────── 流量消耗/测速 工具 ──────────────────────┐${C_RESET}"
    show_status
    echo "${C_BOLD}├──────────────────────────────── 菜 单 ─────────────────────────┤${C_RESET}"
    echo "  1) 开始消耗"
    echo "  2) 限制模式"
    echo "  3) 停止全部线程"
    echo "  4) 查看地址池"
    echo "  5) 设置/关闭定时汇总"
    echo "  6) 限速设置"
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
