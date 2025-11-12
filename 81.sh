#!/usr/bin/env bash
# 全球可选地区的 DNS 连通性/时延测试（交互式选择 + 彩色输出 + CSV 导出）
# 用法：
#   交互：bash dns_ping_check.sh
#   非交互：bash dns_ping_check.sh -r US -c 15 csv
#   自定义文件：bash dns_ping_check.sh -r FILE -f dns_list.txt
# 说明：
#   - 默认每目标 ping 10 次；-c 可改。
#   - 默认无论选哪个地区，都会附带 1.1.1.1 与 8.8.8.8；设 NO_ANYCAST=1 可关闭附带。
#   - 设 NO_COLOR=1 可关闭彩色输出。

set -euo pipefail

REGION=""; COUNT=10; CSV_OUT=""; LIST_FILE=""
ALWAYS_INCLUDE_ANYCAST="${NO_ANYCAST:-0}"   # 0=附带 1.1.1.1/8.8.8.8；1=不附带

# ---------- 参数解析（可选） ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region) REGION="${2:-}"; shift 2 ;;
    -c|--count)  COUNT="${2:-10}"; shift 2 ;;
    csv)         CSV_OUT="csv"; shift ;;
    -f|--file)   LIST_FILE="${2:-}"; shift 2 ;;
    *)           shift ;;
  esac
done

# ---------- 颜色 ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'; GREEN=$'\033[32m'; BOLD_GREEN=$'\033[1;32m'
  YELLOW=$'\033[33m'; MAGENTA=$'\033[35m'; RED=$'\033[31m'; CYAN=$'\033[36m'
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
fmt_ms(){ local v="$1"; if [[ "$v" == "N/A" || -z "$v" ]]; then printf "N/A"; else printf "%.3f" "$v"; fi }

# ---------- 全局公共 DNS（anycast） ----------
ANYCAST_DNS=(1.1.1.1 8.8.8.8)

# ---------- 常见地区预设（可随时加/改） ----------
# *KR 韩国（KT/SKB/LG U+）
KR_ISP_DNS=(168.126.63.1 168.126.63.2 210.220.163.82 219.250.36.130 164.124.101.2 164.124.107.9)
# *US 美国（Comcast/Spectrum/AT&T/Level3-Lumen）
US_ISP_DNS=(75.75.75.75 75.75.76.76 209.18.47.61 209.18.47.62 68.94.156.1 68.94.157.1 4.2.2.1 4.2.2.2)
# *CN 中国（114/阿里/腾讯/百度）
CN_ISP_DNS=(114.114.114.114 114.114.115.115 223.5.5.5 223.6.6.6 119.29.29.29 180.76.76.76)
# *TW 中国台湾（HiNet）
TW_ISP_DNS=(168.95.1.1 168.95.192.1)
# *SG 新加坡（Singtel + anycast）
SG_ISP_DNS=(165.21.83.88)
# *DE 德国（DNS.WATCH 公共解析）
DE_ISP_DNS=(84.200.69.80 84.200.70.40)
# *FR 法国（FDN 公共解析）
FR_ISP_DNS=(80.67.169.12 80.67.169.40)
# *HK 香港（暂无稳定公开运营商解析 → 用公共 DNS）
HK_ISP_DNS=()
# *JP 日本（多数运营商 DNS 不公开 → 用公共 DNS）
JP_ISP_DNS=()

# 其它默认的“全球公共组”
GLOBAL_DNS=(1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 94.140.14.14 94.140.15.15 64.6.64.6 64.6.65.6 8.26.56.26 8.20.247.20)

# ---------- 交互选择 ----------
show_presets(){
  cat <<'EOF'
支持的预设（输入两字母 ISO 地区代码）：
  KR  韩国        US  美国        CN  中国        TW  中国台湾
  SG  新加坡      HK  香港        JP  日本        DE  德国
  FR  法国
其它地区：可直接输入国家/地区码（例如 GB、AU、IN、BR...），
若无内置预设，将提示你粘贴自定义 IP 或使用文件导入。
也可输入：
  file  使用自定义文件（-f 指定；每行一个 IP/域名）
  global使用全球公共DNS集合
  list  再看一次这份列表
EOF
}

if [[ -z "$REGION" ]]; then
  show_presets
  while :; do
    read -rp "请输入要测试的地区（ISO 两字母，如 KR/US/JP/...）： " REGION
    REGION="$(echo "$REGION" | tr '[:lower:]' '[:upper:]' | xargs)"
    [[ -n "$REGION" ]] || REGION="GLOBAL"
    case "$REGION" in
      LIST)  show_presets; REGION=""; continue ;;
      FILE|GLOBAL|KR|US|CN|TW|SG|HK|JP|DE|FR) break ;;
      ??)    break ;;  # 任意两字母也放行，后面尝试自定义
      *)     echo "无效输入，请重试或输入 list 查看支持项。"; REGION="";;
    esac
  done
else
  REGION="$(echo "$REGION" | tr '[:lower:]' '[:upper:]')"
fi

# ---------- 按地区组装目标 ----------
targets=()

append_anycast(){
  if [[ "$ALWAYS_INCLUDE_ANYCAST" -eq 0 ]]; then
    targets+=("${ANYCAST_DNS[@]}")
  fi
}

load_region_targets(){
  case "$1" in
    KR) targets=("${KR_ISP_DNS[@]}"); append_anycast ;;
    US) targets=("${US_ISP_DNS[@]}"); append_anycast ;;
    CN) targets=("${CN_ISP_DNS[@]}"); append_anycast ;;
    TW) targets=("${TW_ISP_DNS[@]}"); append_anycast ;;
    SG) targets=("${SG_ISP_DNS[@]}"); append_anycast ;;
    DE) targets=("${DE_ISP_DNS[@]}"); append_anycast ;;
    FR) targets=("${FR_ISP_DNS[@]}"); append_anycast ;;
    HK) targets=(); append_anycast ;; # 暂无内置 → 仅 anycast
    JP) targets=(); append_anycast ;; # 暂无内置 → 仅 anycast
    GLOBAL) targets=("${GLOBAL_DNS[@]}") ;;
    FILE)
      [[ -n "$LIST_FILE" ]] || { read -rp "请输入自定义列表文件路径: " LIST_FILE; }
      [[ -f "$LIST_FILE" ]] || { echo "未找到列表文件：$LIST_FILE"; exit 1; }
      while IFS= read -r line; do
        line="${line%%#*}"; line="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$line" ]] && targets+=("$line")
      done < "$LIST_FILE"
      ;;
    *)
      echo "该地区（$1）暂无内置预设。"
      read -rp "可粘贴该地区要测试的 DNS（空格分隔，留空则仅测试 1.1.1.1/8.8.8.8）： " extra
      if [[ -n "$extra" ]]; then
        for x in $extra; do targets+=("$x"); done
      fi
      append_anycast
      ;;
  esac
}

load_region_targets "$REGION"
[[ ${#targets[@]} -gt 0 ]] || { echo "目标列表为空"; exit 1; }

# 去重（保持顺序）
uniq_targets=()
declare -A seen
for t in "${targets[@]}"; do
  if [[ -z "${seen[$t]:-}" ]]; then uniq_targets+=("$t"); seen[$t]=1; fi
done
targets=("${uniq_targets[@]}")

command -v ping >/dev/null 2>&1 || { echo "未找到 ping 命令"; exit 1; }

# ---------- ping 风格 ----------
PING_STYLE="GNU"
if ping -h 2>&1 | grep -qi busybox; then PING_STYLE="BUSYBOX"
elif ping -h 2>&1 | grep -qi bsd; then PING_STYLE="BSD"; fi

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT; : >"$TMP"

total=${#targets[@]}
echo "地区: ${REGION} | 目标数: $total | 每个目标 ping 次数: $COUNT"
echo "将测试的目标：${targets[*]}"
echo "开始测试 ..."

show_progress(){ local cur="$1" host="$2"; local pct=$(( cur * 100 / total )); printf "\r进度: [%d/%d | %3d%%] 正在测试: %-18s" "$cur" "$total" "$pct" "$host"; }

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
  IFS=',' read -r h loss min avg max mdev <<<"$line"
  minf="$(fmt_ms "$min")"; avgf="$(fmt_ms "$avg")"; maxf="$(fmt_ms "$max")"; mdevf="$(fmt_ms "$mdev")"
  loss_num="$(printf "%s" "$loss" | tr -d '%')"
  if awk -v l="$loss_num" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  avg_color="$(avg_color_for_value "$avgf")"
  printf "\r\033[2K"
  printf "[%d/%d] %-18s | 丢包 %s%s%s | 最小 %sms | 平均 %s%sms%s | 最大 %sms | 抖动 %sms\n" \
    "$i" "$total" "$h" \
    "$loss_color" "$loss" "$RESET" \
    "$minf" "$avg_color" "$avgf" "$RESET" "$maxf" "$mdevf"
  echo "$line" >> "$TMP"
done

echo
printf "%s%-22s %-8s %-10s %-10s %-10s %-10s%s\n" "$CYAN" "目标" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动" "$RESET"
echo "--------------------------------------------------------------------------------"
awk -F, '{loss=$2; gsub(/%/,"",loss); if(loss==""||loss=="N/A") loss=100;
          avg=$4; if(avg==""||avg=="N/A") avgv=999999; else avgv=avg+0;
          printf "%s,%s,%s,%.6f,%s,%s\n",$1,loss,$3,avgv,$5,$6}' "$TMP" \
| sort -t, -k2n -k4n \
| while IFS=, read -r host lossn min avgn max mdev; do
    printf -v host_cell "%-22s" "$host"
    printf -v loss_cell "%-8s"  "$(printf "%.1f%%" "$lossn")"
    if awk -v a="$avgn" 'BEGIN{exit (a>=999999)?0:1}'; then avg_disp="N/A"; else printf -v avg_disp "%.3f" "$avgn"; fi
    printf -v min_cell "%-10s" "$min"; printf -v avg_cell "%-10s" "$avg_disp"
    printf -v max_cell "%-10s" "$max"; printf -v mdev_cell "%-10s" "$mdev"
    if awk -v l="$lossn" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
    avg_color="$(avg_color_for_value "$avg_disp")"
    printf "%-22s %s%s%s %s%-10s%s %-10s %-10s %-10s\n" \
      "$host_cell" "$loss_color" "$loss_cell" "$RESET" "$avg_color" "$avg_cell" "$RESET" "$min_cell" "$max_cell" "$mdev_cell"
  done

if [[ "$CSV_OUT" == "csv" ]]; then
  OUT="dns_ping_results.csv"
  echo "host,loss,min,avg,max,mdev" > "$OUT"
  cat "$TMP" >> "$OUT"
  echo; echo "已导出 CSV: $OUT"
fi
