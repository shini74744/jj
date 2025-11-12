#!/usr/bin/env bash
# 用法:
#   ./dns_ping_check.sh [list_file] [count] [csv]
#   list_file: 可选，目标IP/域名每行一个；省略则用内置公共DNS
#   count    : 可选，每个目标ping包数(默认10)
#   csv      : 可选，传 "csv" 则导出 dns_ping_results.csv
# 说明: 终端支持ANSI时按“平均延迟”着色；丢包>0也会标红。设置 NO_COLOR=1 可关闭彩色输出。

set -euo pipefail

LIST_FILE="${1:-}"
COUNT="${2:-10}"
CSV_OUT="${3:-}"

# 内置公共DNS
builtin_dns=(
  1.1.1.1 1.0.0.1
  8.8.8.8 8.8.4.4
  9.9.9.9 149.112.112.112
  208.67.222.222 208.67.220.220
  94.140.14.14 94.140.15.15
  64.6.64.6 64.6.65.6
  8.26.56.26 8.20.247.20
)

# 颜色（自动检测TTY；NO_COLOR禁用）
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'
  GREEN=$'\033[32m'
  BOLD_GREEN=$'\033[1;32m'
  YELLOW=$'\033[33m'
  MAGENTA=$'\033[35m'
  RED=$'\033[31m'
  CYAN=$'\033[36m'
else
  RESET=""; GREEN=""; BOLD_GREEN=""; YELLOW=""; MAGENTA=""; RED=""; CYAN=""
fi

avg_color_for_value() {
  local a="$1"
  if [[ "$a" == "N/A" || -z "$a" ]]; then printf "%s" "$YELLOW"; return; fi
  if awk -v a="$a" 'BEGIN{exit !(a<1)}';   then printf "%s" "$BOLD_GREEN"; return; fi
  if awk -v a="$a" 'BEGIN{exit !(a<5)}';   then printf "%s" "$GREEN";      return; fi
  if awk -v a="$a" 'BEGIN{exit !(a<20)}';  then printf "%s" "$YELLOW";     return; fi
  if awk -v a="$a" 'BEGIN{exit !(a<50)}';  then printf "%s" "$MAGENTA";    return; fi
  printf "%s" "$RED"
}

fmt_ms() {  # 把数值格式化为 3 位小数，N/A 原样
  local v="$1"
  if [[ "$v" == "N/A" || -z "$v" ]]; then printf "N/A"; else printf "%.3f" "$v"; fi
}

# 读取目标
targets=()
if [[ -n "$LIST_FILE" ]]; then
  [[ -f "$LIST_FILE" ]] || { echo "未找到列表文件: $LIST_FILE"; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] && targets+=("$line")
  done < "$LIST_FILE"
else
  targets=("${builtin_dns[@]}")
fi
[[ ${#targets[@]} -gt 0 ]] || { echo "目标列表为空"; exit 1; }

command -v ping >/dev/null 2>&1 || { echo "未找到 ping 命令"; exit 1; }

# 判断 ping 风格
PING_STYLE="GNU"
if ping -h 2>&1 | grep -qi busybox; then
  PING_STYLE="BUSYBOX"
elif ping -h 2>&1 | grep -qi bsd; then
  PING_STYLE="BSD"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
: >"$TMP"

total=${#targets[@]}
echo "目标数: $total | 每个目标 ping 次数: $COUNT"
echo "开始测试 ..."

# 进度行
show_progress() {
  local cur="$1" host="$2"
  local pct=$(( cur * 100 / total ))
  printf "\r进度: [%d/%d | %3d%%] 正在测试: %-18s" "$cur" "$total" "$pct" "$host"
}

# 单目标测试 -> CSV: host,loss,min,avg,max,mdev
ping_once() {
  local host="$1" count="$2" out loss rline rmin ravg rmax rdev
  case "$PING_STYLE" in
    GNU)     out="$(ping -n -c "$count" -W 2 "$host" 2>&1)" || true ;;
    BUSYBOX) out="$(ping -n -c "$count" -W 2 -w $((count*3)) "$host" 2>&1)" || true ;;
    BSD)     out="$(ping -n -c "$count" "$host" 2>&1)" || true ;;
  esac
  loss="$(printf "%s" "$out" | awk -F', ' '/packet loss/{print $3}' | sed -e 's/packet loss//' -e 's/ //g')"
  [[ -z "$loss" ]] && loss="$(printf "%s" "$out" | sed -n 's/.* \([0-9.]\+%\) packet loss.*/\1/p' | head -n1)"
  [[ -z "$loss" ]] && loss="100%"
  rline="$(printf "%s" "$out" | grep -E 'rtt|min/avg/max|round-trip' || true)"
  if [[ -n "$rline" ]]; then
    IFS='/' read -r rmin ravg rmax rdev <<<"$(printf "%s" "$rline" | awk -F'=' '{print $2}' | awk '{print $1}')"
  else
    rmin="N/A"; ravg="N/A"; rmax="N/A"; rdev="N/A"
  fi
  if printf "%s" "$out" | grep -qiE 'unknown host|Name or service not known|100% packet loss|Destination .* Unreachable|Request timeout'; then
    loss="100%"; rmin="N/A"; ravg="N/A"; rmax="N/A"; rdev="N/A"
  fi
  printf "%s,%s,%s,%s,%s,%s\n" "$host" "$loss" "$rmin" "$ravg" "$rmax" "$rdev"
}

i=0
for host in "${targets[@]}"; do
  i=$((i+1))
  show_progress "$i" "$host"
  line="$(ping_once "$host" "$COUNT")"
  # 解析结果行，中文+单位+颜色，替换原来的生硬CSV
  IFS=',' read -r h loss min avg max mdev <<<"$line"
  minf="$(fmt_ms "$min")"; avgf="$(fmt_ms "$avg")"; maxf="$(fmt_ms "$max")"; mdevf="$(fmt_ms "$mdev")"
  # 丢包颜色
  loss_num="$(printf "%s" "$loss" | tr -d '%')"
  if awk -v l="$loss_num" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  # 平均延迟颜色
  avg_color="$(avg_color_for_value "$avgf")"
  # 擦除进度行并打印中文化的结果行
  printf "\r\033[2K"
  printf "[%d/%d] %-18s | 丢包 %s%s%s | 最小 %sms | 平均 %s%sms%s | 最大 %sms | 抖动 %sms\n" \
    "$i" "$total" "$h" \
    "$loss_color" "$loss" "$RESET" \
    "$minf" \
    "$avg_color" "$avgf" "$RESET" \
    "$maxf" "$mdevf"
  # 仍把原始CSV写入临时文件，便于后续排序/导出
  echo "$line" >> "$TMP"
done

echo
# 中文表头
printf "%s%-22s %-8s %-10s %-10s %-10s %-10s%s\n" "$CYAN" "目标" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动" "$RESET"
echo "--------------------------------------------------------------------------------"

# 排序并彩色输出汇总
awk -F, '{loss=$2; gsub(/%/,"",loss); if(loss==""||loss=="N/A") loss=100;
          avg=$4; if(avg==""||avg=="N/A") avgv=999999; else avgv=avg+0;
          printf "%s,%s,%s,%.6f,%s,%s\n",$1,loss,$3,avgv,$5,$6}' "$TMP" \
| sort -t, -k2n -k4n \
| while IFS=, read -r host lossn min avgn max mdev; do
    printf -v host_cell "%-22s" "$host"
    printf -v loss_cell "%-8s"  "$(printf "%.1f%%" "$lossn")"
    if awk -v a="$avgn" 'BEGIN{exit (a>=999999)?0:1}'; then avg_disp="N/A"; else printf -v avg_disp "%.3f" "$avgn"; fi
    printf -v min_cell  "%-10s" "$min"
    printf -v avg_cell  "%-10s" "$avg_disp"
    printf -v max_cell  "%-10s" "$max"
    printf -v mdev_cell "%-10s" "$mdev"
    # 颜色
    if awk -v l="$lossn" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
    avg_color="$(avg_color_for_value "$avg_disp")"
    printf "%-22s %s%s%s %s%-10s%s %-10s %-10s %-10s\n" \
      "$host_cell" \
      "$loss_color" "$loss_cell" "$RESET" \
      "$avg_color"  "$avg_cell"  "$RESET" \
      "$min_cell" "$max_cell" "$mdev_cell"
  done

# 可选CSV导出
if [[ "${CSV_OUT:-}" == "csv" ]]; then
  OUT="dns_ping_results.csv"
  echo "host,loss,min,avg,max,mdev" > "$OUT"
  cat "$TMP" >> "$OUT"
  echo
  echo "已导出 CSV: $OUT"
fi
