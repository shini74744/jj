#!/usr/bin/env bash
# 从 publicdnsserver.com 抓取国家 DNS 并批量 ping（全球可用）
# 新增/修正：
#   - 实时结果与汇总显示「地区 / ASN / 公司」，带缓存与回退
#   - 汇总表的“编号”= 测试阶段的原始编号（例如上面测的是 #31，这里仍显示 31）
#   - 避免在管道里 while：使用排序临时文件，保证关联数组可见

set -euo pipefail

REGION=""; COUNT=10; TOPN=30
ALWAYS_INCLUDE_ANYCAST="${NO_ANYCAST:-0}"   # 0=附带 1.1.1.1/8.8.8.8；1=不附带
ANYCAST=(1.1.1.1 8.8.8.8)

# ---------- 参数 ----------
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

# ---------- 名称 → slug ----------
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

# ---------- 拉取 DNS 列表 ----------
fetch_dns_list() {
  local slug="$1" tmp="$(mktemp)"
  local url_txt="https://publicdnsserver.com/download/${slug}.txt"
  local url_html="https://publicdnsserver.com/${slug}/"
  if curl -fsSL "$url_txt" -o "$tmp" && grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}|:' "$tmp"; then
    head -n "$TOPN" "$tmp"; rm -f "$tmp"; return 0
  fi
  if curl -fsSL "$url_html" -o "$tmp" 2>/dev/null && grep -q . "$tmp"; then
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$tmp" | sort -u | head -n "$TOPN"
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# ---------- 元数据缓存/查询 ----------
declare -A META_LOC META_ASN META_ORG INDEX_MAP
get_meta() {
  local ip="$1"
  if [[ -n "${META_LOC[$ip]:-}" ]]; then
    printf "%s|%s|%s" "${META_LOC[$ip]}" "${META_ASN[$ip]}" "${META_ORG[$ip]}"; return
  fi
  # ip-api（IPv4/IPv6均可），免费版有速率限制
  local j; j="$(curl -fsSL "http://ip-api.com/json/$ip?fields=status,country,regionName,city,org,as" -m 5 || true)"
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
  # 回退：Team Cymru（IPv6 支持有限，可能返回空）
  if command -v whois >/dev/null 2>&1 && [[ "$ip" != *:* ]]; then
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

# ---------- 地区输入 ----------
if [[ -z "$REGION" ]]; then
  read -rp "请输入英文国家名（如 Japan / China / United States / South Korea；或 US/UK/KR）： " REGION
fi
REGION="$(echo "$REGION" | xargs)"
[[ -n "$REGION" ]] || { echo "未输入国家/地区"; exit 1; }

SLUG="$(normalize_slug "$REGION")"
[[ -n "$SLUG" ]] || { echo "无法解析 slug（请用英文全名，例如 United States）"; exit 1; }

# ---------- 目标列表 ----------
mapfile -t targets < <(fetch_dns_list "$SLUG" || true)
[[ ${#targets[@]} -gt 0 ]] || { echo "拉取失败：$REGION / slug=$SLUG"; exit 1; }
if [[ "$ALWAYS_INCLUDE_ANYCAST" -eq 0 ]]; then targets+=("${ANYCAST[@]}"); fi
# 去重
declare -A seen; uniq_targets=()
for t in "${targets[@]}"; do
  [[ -z "${seen[$t]:-}" ]] && uniq_targets+=("$t") && seen[$t]=1
done
targets=("${uniq_targets[@]}")

# ---------- ping 风格 ----------
PING_STYLE="GNU"
if ping -h 2>&1 | grep -qi busybox; then PING_STYLE="BUSYBOX"
elif ping -h 2>&1 | grep -qi bsd; then PING_STYLE="BSD"; fi

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT; : >"$TMP"

total=${#targets[@]}
echo "地区: $REGION（slug: $SLUG）| 目标数: $total | 每个目标 ping 次数: $COUNT"
echo "将测试的目标：${targets[*]}"
echo "开始测试 ..."

show_progress(){ local cur="$1" host="$2"; local pct=$(( cur * 100 / total )); printf "\r进度: [%d/%d | %3d%%] #%-3d 正在测试: %-30s" "$cur" "$total" "$pct" "$cur" "$host"; }

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

# ---------- 测试循环：记录原始编号 + 元数据 ----------
i=0
for host in "${targets[@]}"; do
  i=$((i+1))
  INDEX_MAP["$host"]="$i"                  # 记录“测试时编号”
  show_progress "$i" "$host"

  meta="$(get_meta "$host")"               # 缓存：META_LOC/ASN/ORG
  IFS='|' read -r loc asn org <<<"$meta"
  [[ -z "$loc" ]] && loc="N/A"; [[ -z "$asn" ]] && asn="N/A"; [[ -z "$org" ]] && org="N/A"

  line="$(ping_once "$host" "$COUNT")"     # 执行 ping
  IFS=',' read -r h loss min avg max mdev <<<"$line"
  minf="$(fmt_ms "$min")"; avgf="$(fmt_ms "$avg")"; maxf="$(fmt_ms "$max")"; mdevf="$(fmt_ms "$mdev")"
  loss_num="$(fmt_loss "$loss")"
  if awk -v l="$loss_num" 'BEGIN{exit !(l>0)}'; then loss_color="$RED"; else loss_color="$BOLD_GREEN"; fi
  avg_color="$(avg_color_for_value "$avgf")"

  printf -v loc_cell  "%-18.18s" "$loc"
  printf -v asn_cell  "%-10.10s" "$asn"
  printf -v org_cell  "%-24.24s" "$org"

  printf "\r\033[2K"
  printf "[%d/%d] #%-3d %-30s | 地区 %-18s | ASN %-10s | 公司 %-24s | 丢包 %s%s%%%s | 最小 %sms | 平均 %s%sms%s | 最大 %sms | 抖动 %sms\n" \
    "$i" "$total" "$i" "$h" \
    "$loc_cell" "$asn_cell" "$org_cell" \
    "$loss_color" "$loss_num" "$RESET" \
    "$minf" "$avg_color" "$avgf" "$RESET" "$maxf" "$mdevf"

  echo "$line" >> "$TMP"                   # 保存到临时文件（用于排序）
done

# ---------- 汇总：按“丢包→平均”排序 + 显示原始编号 ----------
echo
printf "%s%-6s %-30s %-18s %-10s %-24s %-8s %-10s %-10s %-10s %-10s%s\n" \
  "$CYAN" "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动" "$RESET"
echo "----------------------------------------------------------------------------------------------------------------------------------"

SORTED="$(mktemp)"
awk -F, '{
  loss=$2; gsub(/%/,"",loss); if(loss==""||loss=="N/A") loss=100;
  avg=$4; if(avg==""||avg=="N/A") avgv=999999; else avgv=avg+0;
  printf "%s,%s,%s,%.6f,%s,%s\n",$1,loss,$3,avgv,$5,$6
}' "$TMP" | sort -t, -k2n -k4n > "$SORTED"

while IFS=, read -r host lossn min avgn max mdev; do
  orig="${INDEX_MAP[$host]:-?}"            # 取“测试时编号”
  loc="${META_LOC[$host]:-N/A}"
  asn="${META_ASN[$host]:-N/A}"
  org="${META_ORG[$host]:-N/A}"

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
    "$orig" "$host_cell" "$loc_cell" "$asn_cell" "$org_cell" \
    "$loss_color" "$loss_cell" "$RESET" \
    "$avg_color"  "$avg_cell" "$RESET" \
    "$min_cell" "$max_cell" "$mdev_cell"
done < "$SORTED"
rm -f "$SORTED"
