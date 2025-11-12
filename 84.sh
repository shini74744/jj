#!/usr/bin/env bash
# 从 publicdnsserver.com 按国家抓取 DNS 并批量 ping（全球可用）
# 功能：
#   - 交互或参数指定国家名（英文），自动下载该国 DNS 列表并测速
#   - 结果、汇总表中文显示，颜色标注（丢包红；平均延迟分级着色）
#   - 进度行 & 汇总表均带编号
# 依赖：curl, awk, ping（GNU/BusyBox/BSD均支持）
#
# 用法：
#   交互：bash dns_ping_pds.sh
#   指定：bash dns_ping_pds.sh -r "United States" -c 15 -n 40
#   仅该国DNS（不附带 1.1.1.1 / 8.8.8.8）：NO_ANYCAST=1 bash dns_ping_pds.sh -r Japan
#
# 选项：
#   -r/--region  英文国家名或少量缩写（US/UK/KR 等）
#   -c/--count   每目标 ping 次数（默认 10）
#   -n/--top     仅取前 N 个地址（默认 30）
#
# 环境变量：
#   NO_ANYCAST=1   不附带 1.1.1.1 与 8.8.8.8（默认附带）

set -euo pipefail

REGION=""; COUNT=10; TOPN=30
ALWAYS_INCLUDE_ANYCAST="${NO_ANYCAST:-0}"   # 0=附带 anycast；1=不附带

# -------- 参数解析 --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region) REGION="${2:-}"; shift 2 ;;
    -c|--count)  COUNT="${2:-10}"; shift 2 ;;
    -n|--top)    TOPN="${2:-30}"; shift 2 ;;
    *) shift ;;
  esac
done

# -------- 依赖检测 --------
command -v curl >/dev/null || { echo "缺少 curl"; exit 1; }
command -v awk  >/dev/null || { echo "缺少 awk";  exit 1; }
command -v ping >/dev/null || { echo "缺少 ping"; exit 1; }

# -------- 颜色 --------
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
fmt_loss(){ local s="$1"; s="${s%%%}"; [[ -z "$s" ]] && s="100"; printf "%s" "$s"; }

ANYCAST=(1.1.1.1 8.8.8.8)

# -------- 英文国家名/缩写 → slug --------
normalize_slug() {
  local raw="$1"
  local s
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"  # 小写
  s="${s//&/and}"                                         # & → and
  s="$(printf '%s' "$s" | sed 's/[^a-z0-9]//g')"          # 仅留 a-z0-9

  # 少量必要别名；其余请用英文国家全名
  case "$s" in
    us|usa|unitedstatesofamerica|unitedstates) echo "unitedstates"; return ;;
    uk|gb|greatbritain|britain|unitedkingdom)  echo "unitedkingdom"; return ;;
    kr|korea|republicofkorea|southkorea)       echo "southkorea"; return ;;
    kp|northkorea|dprk)                        echo "northkorea"; return ;;
    ae|uae|unitedarabemirates)                 echo "unitedarabemirates"; return ;;
    ci|cotedivoire|ivoire|ivorycoast)          echo "ivorycoast"; return ;;
    cz|czech|czechrepublic)                    echo "czechia"; return ;;
  esac
  echo "$s"
}

# -------- 拉取该国 DNS 列表（优先 /download/<slug>.txt，回退抓页面） --------
fetch_dns_list() {
  local slug="$1" tmp="$(mktemp)"
  local url_txt="https://publicdnsserver.com/download/${slug}.txt"
  local url_html="https://publicdnsserver.com/${slug}/"

  # 1) 纯文本下载
  if curl -fsSL "$url_txt" -o "$tmp" && grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' "$tmp"; then
    head -n "$TOPN" "$tmp"; rm -f "$tmp"; return 0
  fi
  # 2) 抓取页面并提取 IPv4
  if curl -fsSL "$url_html" -o "$tmp" 2>/dev/null && grep -q . "$tmp"; then
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$tmp" | sort -u | head -n "$TOPN"
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# -------- 交互输入地区 --------
if [[ -z "$REGION" ]]; then
  read -rp "请输入英文国家名（如 Japan / China / United States / South Korea；或 US/UK/KR）： " REGION
fi
REGION="$(echo "$REGION" | xargs)"
[[ -n "$REGION" ]] || { echo "未输入国家/地区"; exit 1; }

SLUG="$(normalize_slug "$REGION")"
if [[ -z "$SLUG" ]]; then
  echo "无法从“$REGION”解析 slug，请改用英文国家名（如 Japan、United States、South Korea）。"
  exit 1
fi

# -------- 获取目标列表 --------
mapfile -t targets < <(fetch_dns_list "$SLUG" || true)
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "从 publicdnsserver.com 获取失败（输入：$REGION / slug：$SLUG）。"
  echo "请改用英文国家全名（例如 United States、United Kingdom、South Korea、Czechia、Ivory Coast）。"
  exit 1
fi

# 附带 anycast 解析器
if [[ "$ALWAYS_INCLUDE_ANYCAST" -eq 0 ]]; then
  targets+=("${ANYCAST[@]}")
fi

# 去重（保持顺序）
declare -A seen; uniq_targets=()
for t in "${targets[@]}"; do
  [[ -z "${seen[$t]:-}" ]] && uniq_targets+=("$t") && seen[$t]=1
done
targets=("${uniq_targets[@]}")

# -------- 检测 ping 风格 --------
PING_STYLE="GNU"
if ping -h 2>&1 | grep -qi busybox; then PING_STYLE="BUSYBOX"
elif ping -h 2>&1 | grep -qi bsd; then PING_STYLE="BSD"; fi

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT; : >"$TMP"

total=${#targets[@]}
echo "地区: $REGION（slug: $SLUG）| 目标数: $total | 每个目标 ping 次数: $COUNT"
echo "将测试的目标：${targets[*]}"
echo "开始测试 ..."

# 进度行（带编号）
show_progress(){ local cur="$1" host="$2"; local pct=$(( cur * 100 / total )); printf "\r进度: [%d/%d | %3d%%] #%-3d 正在测试: %-30s" "$cur" "$total" "$pct" "$cur" "$host"; }

# 单目标测试：输出 CSV 一行 host,loss,min,avg,max,mdev
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

# 主循环：逐个测试 + 实时打印（带编号）
i=0
for host in "${targets[@]}"; do
  i=$((i+1))
  show_progress "$i" "$host"
  line="$(ping_once "$host" "$COUNT")"
  IFS=',' read -r h loss min avg max mdev <<<"$line"
  minf="$(fmt_ms "$min")"; avgf="$(fmt_ms "$avg")"; maxf="$(fmt_ms "$max")"; mdevf="$(fmt_ms "$mdev")"
  loss_num="$(fmt_loss "$loss")"
  if awk -v l="$loss_num" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  avg_color="$(avg_color_for_value "$avgf")"
  # 擦除进度行并打印结果行（带编号）
  printf "\r\033[2K"
  printf "[%d/%d] #%-3d %-30s | 丢包 %s%s%%%s | 最小 %sms | 平均 %s%sms%s | 最大 %sms | 抖动 %sms\n" \
    "$i" "$total" "$i" "$h" \
    "$loss_color" "$loss_num" "$RESET" \
    "$minf" "$avg_color" "$avgf" "$RESET" "$maxf" "$mdevf"
  echo "$line" >> "$TMP"
done

# -------- 汇总表（带编号，按“丢包→平均延迟”排序） --------
echo
printf "%s%-6s %-39s %-8s %-10s %-10s %-10s %-10s%s\n" \
  "$CYAN" "编号" "目标" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动" "$RESET"
echo "--------------------------------------------------------------------------------------------"

idx=0
awk -F, '{loss=$2; gsub(/%/,"",loss); if(loss==""||loss=="N/A") loss=100;
          avg=$4; if(avg==""||avg=="N/A") avgv=999999; else avgv=avg+0;
          printf "%s,%s,%s,%.6f,%s,%s\n",$1,loss,$3,avgv,$5,$6}' "$TMP" \
| sort -t, -k2n -k4n \
| while IFS=, read -r host lossn min avgn max mdev; do
    idx=$((idx+1))
    # 对齐
    printf -v host_cell "%-39s" "$host"
    printf -v loss_cell "%-8s"  "$(printf "%.1f%%" "$lossn")"
    if awk -v a="$avgn" 'BEGIN{exit (a>=999999)?0:1}'; then avg_disp="N/A"; else printf -v avg_disp "%.3f" "$avgn"; fi
    printf -v min_cell  "%-10s" "$min"
    printf -v avg_cell  "%-10s" "$avg_disp"
    printf -v max_cell  "%-10s" "$max"
    printf -v mdev_cell "%-10s" "$mdev"
    # 颜色
    if awk -v l="$lossn" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
    avg_color="$(avg_color_for_value "$avg_disp")"
    # 编号 + 指标
    printf "%-6s %-39s %s%s%s %s%-10s%s %-10s %-10s %-10s\n" \
      "$idx" "$host_cell" \
      "$loss_color" "$loss_cell" "$RESET" \
      "$avg_color"  "$avg_cell"  "$RESET" \
      "$min_cell" "$max_cell" "$mdev_cell"
  done
