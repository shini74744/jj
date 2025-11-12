#!/usr/bin/env bash
# 从 publicdnsserver.com 拉取国家 DNS 列表并批量 ping（全球可用）
# 新增：显示每个 DNS IP 的「位置(国家-城市) / ASN / 公司」，实时行与汇总表均包含
# 依赖：curl, awk, ping（GNU/BusyBox/BSD 均可）；可选 whois（用于元数据回退）
#
# 用法：
#   交互：bash dns_ping_pds.sh
#   指定：bash dns_ping_pds.sh -r "United States" -c 15 -n 40
#   仅该国列表（不附带 1.1.1.1/8.8.8.8）：NO_ANYCAST=1 bash dns_ping_pds.sh -r Japan
#
# 选项：
#   -r/--region  英文国家名或少量缩写（US/UK/KR 等；建议用英文全名，如 United States）
#   -c/--count   每目标 ping 次数（默认 10）
#   -n/--top     仅取前 N 个地址（默认 30）
#
# 注意：ip-api 免费额度约 45 次/分钟，如一次抓取非常多 IP 可能会被限速。

set -euo pipefail

REGION=""; COUNT=10; TOPN=30
ALWAYS_INCLUDE_ANYCAST="${NO_ANYCAST:-0}"   # 0=附带 anycast；1=不附带
ANYCAST=(1.1.1.1 8.8.8.8)

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region) REGION="${2:-}"; shift 2 ;;
    -c|--count)  COUNT="${2:-10}"; shift 2 ;;
    -n|--top)    TOPN="${2:-30}"; shift 2 ;;
    *) shift ;;
  esac
done

# ---------- 依赖 ----------
command -v curl >/dev/null || { echo "缺少 curl"; exit 1; }
command -v awk  >/dev/null || { echo "缺少 awk";  exit 1; }
command -v ping >/dev/null || { echo "缺少 ping"; exit 1; }

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
fmt_loss(){ local s="$1"; s="${s%%%}"; [[ -z "$s" ]] && s="100"; printf "%s" "$s"; }

# ---------- 英文国家名/缩写 → slug ----------
normalize_slug() {
  local raw="$1"
  local s
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  s="${s//&/and}"
  s="$(printf '%s' "$s" | sed 's/[^a-z0-9]//g')"
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

# ---------- 拉取该国 DNS 列表（优先 /download/<slug>.txt，回退抓页面） ----------
fetch_dns_list() {
  local slug="$1" tmp="$(mktemp)"
  local url_txt="https://publicdnsserver.com/download/${slug}.txt"
  local url_html="https://publicdnsserver.com/${slug}/"
  if curl -fsSL "$url_txt" -o "$tmp" && grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}|:' "$tmp"; then
    head -n "$TOPN" "$tmp"; rm -f "$tmp"; return 0
  fi
  if curl -fsSL "$url_html" -o "$tmp" 2>/dev/null && grep -q . "$tmp"; then
    # 页面回退仅抽取 IPv4；若需要 IPv6 可自行增强
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$tmp" | sort -u | head -n "$TOPN"
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# ---------- 元数据查询（位置/ASN/公司），带缓存 ----------
declare -A META_LOC META_ASN META_ORG
get_meta() {
  local ip="$1"
  if [[ -n "${META_LOC[$ip]:-}" ]]; then
    printf "%s|%s|%s" "${META_LOC[$ip]}" "${META_ASN[$ip]}" "${META_ORG[$ip]}"; return
  fi
  # ip-api（优先）
  local j; j="$(curl -fsSL "http://ip-api.com/json/$ip?fields=status,country,regionName,city,org,as" -m 4 || true)"
  if printf "%s" "$j" | grep -q '"status":"success"'; then
    local country region city asfield org asn loc
    country="$(printf "%s" "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')"
    region="$( printf "%s" "$j" | sed -n 's/.*"regionName":"\([^"]*\)".*/\1/p')"
    city="$(   printf "%s" "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')"
    asfield="$(printf "%s" "$j" | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')"
    org="$(    printf "%s" "$j" | sed -n 's/.*"org":"\([^"]*\)".*/\1/p')"
    asn="$(printf "%s" "$asfield" | awk '{print $1}')"
    [[ -z "$org" ]] && org="$(printf "%s" "$asfield" | cut -d' ' -f2-)"
    loc="$country"; [[ -n "$city" ]] && loc="$country-$city" || { [[ -n "$region" ]] && loc="$country-$region"; }
    [[ -z "$loc" ]] && loc="N/A"; [[ -z "$asn" ]] && asn="N/A"; [[ -z "$org" ]] && org="N/A"
    META_LOC[$ip]="$loc"; META_ASN[$ip]="$asn"; META_ORG[$ip]="${org//|//}"
    printf "%s|%s|%s" "$loc" "$asn" "${META_ORG[$ip]}"; return
  fi
  # 回退：Team Cymru whois（仅 ASN/国家简码/公司）
  if command -v whois >/dev/null 2>&1; then
    local resp; resp="$(whois -h whois.cymru.com -v "$ip" 2>/dev/null | tail -n1)"
    local asn cc org
    asn="$(echo "$resp" | awk -F'|' '{gsub(/ /,"",$1); print $1}')"
    cc="$( echo "$resp" | awk -F'|' '{gsub(/ /,"",$4); print $4}')"
    org="$(echo "$resp" | awk -F'|' '{sub(/^[ ]*/,"",$7); print $7}')"
    [[ -z "$asn" ]] && asn="N/A"; [[ -z "$cc" ]] && cc="N/A"; [[ -z "$org" ]] && org="N/A"
    META_LOC[$ip]="$cc"; META_ASN[$ip]="$asn"; META_ORG[$ip]="${org//|//}"
    printf "%s|%s|%s" "$cc" "$asn" "${META_ORG[$ip]}"; return
  fi
  META_LOC[$ip]="N/A"; META_ASN[$ip]="N/A"; META_ORG[$ip]="N/A"
  printf "N/A|N/A|N/A"
}

# ---------- 输入地区 ----------
if [[ -z "$REGION" ]]; then
  read -rp "请输入英文国家名（如 Japan / China / United States / South Korea；或 US/UK/KR）： " REGION
fi
REGION="$(echo "$REGION" | xargs)"
[[ -n "$REGION" ]] || { echo "未输入国家/地区"; exit 1; }

SLUG="$(normalize_slug "$REGION")"
if [[ -z "$SLUG" ]]; then
  echo "无法从“$REGION”解析 slug（请用英文全名，如 Japan、United States、South Korea）"; exit 1
fi

# ---------- 拉取目标 ----------
mapfile -t targets < <(fetch_dns_list "$SLUG" || true)
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "从 publicdnsserver.com 获取失败（输入：$REGION / slug：$SLUG）。"
  echo "请改用英文国家全名（如 United States、United Kingdom、South Korea、Czechia、Ivory Coast）。"
  exit 1
fi
if [[ "$ALWAYS_INCLUDE_ANYCAST" -eq 0 ]]; then targets+=("${ANYCAST[@]}"); fi

# 去重（保持顺序）
declare -A seen; uniq_targets=()
for t in "${targets[@]}"; do
  [[ -z "${seen[$t]:-}" ]] && uniq_targets+=("$t") && seen[$t]=1
done
targets=("${uniq_targets[@]}")

# ---------- 检测 ping 风格 ----------
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
    GNU)
      if [[ "$host" == *:* ]]; then out="$(ping -6 -n -c "$count" -W 2 "$host" 2>&1)" || true
      else out="$(ping -4 -n -c "$count" -W 2 "$host" 2>&1)" || true; fi ;;
    BUSYBOX)
      if [[ "$host" == *:* ]]; then out="$(ping -6 -n -c "$count" -W 2 -w $((count*3)) "$host" 2>&1)" || true
      else out="$(ping -4 -n -c "$count" -W 2 -w $((count*3)) "$host" 2>&1)" || true; fi ;;
    BSD)
      if [[ "$host" == *:* ]]; then out="$(ping -6 -n -c "$count" "$host" 2>&1)" || true
      else out="$(ping -4 -n -c "$count" "$host" 2>&1)" || true; fi ;;
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

# 主循环：逐个测试 + 实时打印（带编号 + 位置/ASN/公司）
i=0
for host in "${targets[@]}"; do
  i=$((i+1))
  show_progress "$i" "$host"

  # 查询元数据（位置/ASN/公司），带缓存与回退
  meta="$(get_meta "$host")"
  IFS='|' read -r loc asn org <<<"$meta"
  [[ -z "$loc" ]] && loc="N/A"; [[ -z "$asn" ]] && asn="N/A"; [[ -z "$org" ]] && org="N/A"

  line="$(ping_once "$host" "$COUNT")"
  IFS=',' read -r h loss min avg max mdev <<<"$line"
  minf="$(fmt_ms "$min")"; avgf="$(fmt_ms "$avg")"; maxf="$(fmt_ms "$max")"; mdevf="$(fmt_ms "$mdev")"
  loss_num="$(fmt_loss "$loss")"
  if awk -v l="$loss_num" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  avg_color="$(avg_color_for_value "$avgf")"

  # 对齐字段宽度
  printf -v loc_cell  "%-18.18s" "$loc"
  printf -v asn_cell  "%-10.10s" "$asn"
  printf -v org_cell  "%-24.24s" "$org"

  # 擦除进度行并打印结果行
  printf "\r\033[2K"
  printf "[%d/%d] #%-3d %-30s | 地区 %-18s | ASN %-10s | 公司 %-24s | 丢包 %s%s%%%s | 最小 %sms | 平均 %s%sms%s | 最大 %sms | 抖动 %sms\n" \
    "$i" "$total" "$i" "$h" \
    "$loc_cell" "$asn_cell" "$org_cell" \
    "$loss_color" "$loss_num" "$RESET" \
    "$minf" "$avg_color" "$avgf" "$RESET" "$maxf" "$mdevf"

  # 记录 ping 结果（CSV）供排序
  echo "$line" >> "$TMP"
done

# ---------- 汇总表（带编号 + 位置/ASN/公司，按“丢包→平均延迟”排序） ----------
echo
printf "%s%-6s %-30s %-18s %-10s %-24s %-8s %-10s %-10s %-10s %-10s%s\n" \
  "$CYAN" "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动" "$RESET"
echo "----------------------------------------------------------------------------------------------------------------------------------"

idx=0
# 用进程替代管道，避免 subshell 读不到关联数组
while IFS=, read -r host lossn min avgn max mdev; do
  idx=$((idx+1))
  # 取元数据缓存
  loc="${META_LOC[$host]:-N/A}"
  asn="${META_ASN[$host]:-N/A}"
  org="${META_ORG[$host]:-N/A}"

  # 对齐与着色
  printf -v host_cell "%-30s" "$host"
  printf -v loc_cell  "%-18.18s" "$loc"
  printf -v asn_cell  "%-10.10s" "$asn"
  printf -v org_cell  "%-24.24s" "$org"
  printf -v loss_cell "%-8s"  "$(printf "%.1f%%" "$lossn")"
  if awk -v a="$avgn" 'BEGIN{exit (a>=999999)?0:1}'; then avg_disp="N/A"; else printf -v avg_disp "%.3f" "$avgn"; fi
  printf -v min_cell  "%-10s" "$min"
  printf -v avg_cell  "%-10s" "$avg_disp"
  printf -v max_cell  "%-10s" "$max"
  printf -v mdev_cell "%-10s" "$mdev"
  if awk -v l="$lossn" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  avg_color="$(avg_color_for_value "$avg_disp")"

  printf "%-6s %-30s %-18s %-10s %-24s %s%s%s %s%-10s%s %-10s %-10s %-10s\n" \
    "$idx" "$host_cell" "$loc_cell" "$asn_cell" "$org_cell" \
    "$loss_color" "$loss_cell" "$RESET" \
    "$avg_color"  "$avg_cell" "$RESET" \
    "$min_cell" "$max_cell" "$mdev_cell"
done < <(
  awk -F, '{
    loss=$2; gsub(/%/,"",loss); if(loss==""||loss=="N/A") loss=100;
    avg=$4; if(avg==""||avg=="N/A") avgv=999999; else avgv=avg+0;
    printf "%s,%s,%s,%.6f,%s,%s\n",$1,loss,$3,avgv,$5,$6
  }' "$TMP" | sort -t, -k2n -k4n
)
