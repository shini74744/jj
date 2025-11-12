#!/usr/bin/env bash
# DNS 连通性测试（按国家抓取）— 稳定抓取 + 单行进度
set -u

COUNT=${COUNT:-10}              # 每目标 ping 次数
TOPN=${TOPN:-30}                # 每国家抓取最多目标
SLEEP_META=${SLEEP_META:-0.15}  # ASN/公司查询间隔
META_CACHE_DIR="${META_CACHE_DIR:-/tmp/dns_meta_cache}"
mkdir -p "$META_CACHE_DIR" >/dev/null 2>&1 || true

# ---------------- 工具函数 ----------------
extract_ips() {
  sed -E 's/<[^>]+>/ /g' \
  | tr -c '0-9A-Fa-f:.' '\n' \
  | grep -E '(^([0-9]{1,3}\.){3}[0-9]{1,3}$)|(^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$)' \
  | awk '!seen[$0]++' \
  | awk -F. '
    $0 ~ /:/ { print; next }
    NF==4 {
      ok=1; for(i=1;i<=4;i++){
        if($i !~ /^[0-9]+$/ || $i<0 || $i>255){ ok=0; break }
      }
      if(ok) print $0
    }'
}

is_public_ipv4() {
  local ip="$1"; IFS=. read -r a b c d <<<"$ip" || return 1
  if ((a==10)) || ((a==127)) || ((a==192 && b==168)) || ((a==169 && b==254)) \
     || ((a==172 && b>=16 && b<=31)) || ((a==100 && b>=64 && b<=127)) \
     || ((a==0)) || ((a>=224)); then return 1; fi
  return 0
}

normalize_country_to_slug() {
  local raw="$1" x compact
  x=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  compact=$(printf '%s' "$x" | sed -E 's/[^a-z0-9]+//g')
  case "$compact" in
    jp) echo "japan"; return ;; kr|rok) echo "southkorea"; return ;;
    us|usa) echo "unitedstates"; return ;; uk|gb) echo "unitedkingdom"; return ;;
    ae|uae) echo "unitedarabemirates"; return ;; hk) echo "hongkong"; return ;;
    tw) echo "taiwan"; return ;; cn) echo "china"; return ;; de) echo "germany"; return ;;
    fr) echo "france"; return ;; it) echo "italy"; return ;; es) echo "spain"; return ;;
    ru) echo "russia"; return ;; sg) echo "singapore"; return ;; th) echo "thailand"; return ;;
    vn) echo "vietnam"; return ;; ph) echo "philippines"; return ;; id) echo "indonesia"; return ;;
    my) echo "malaysia"; return ;; au) echo "australia"; return ;; nz) echo "newzealand"; return ;;
    nl) echo "netherlands"; return ;; be) echo "belgium"; return ;; pl) echo "poland"; return ;;
    cz) echo "czechia"; return ;; ch) echo "switzerland"; return ;; at) echo "austria"; return ;;
    se) echo "sweden"; return ;; no) echo "norway"; return ;; fi) echo "finland"; return ;;
    pt) echo "portugal"; return ;; ro) echo "romania"; return ;; hu) echo "hungary"; return ;;
    sk) echo "slovakia"; return ;; si) echo "slovenia"; return ;; gr) echo "greece"; return ;;
    ie) echo "ireland"; return ;; mx) echo "mexico"; return ;; ca) echo "canada"; return ;;
    br) echo "brazil"; return ;; ar) echo "argentina"; return ;; cl) echo "chile"; return ;;
    za) echo "southafrica"; return ;;
  esac
  echo "$(printf '%s' "$x" | sed -E 's/[[:space:]]+//g')"
}

normalize_to_iso2() {
  # 输入可以是 ISO2（jp）、常见英文（Japan / United States / South Korea …）
  local raw="$1" x
  x=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  case "$x" in
    JP|JAPAN) echo "JP"; return ;;
    KR|KOREA|SOUTHKOREA) echo "KR"; return ;;
    US|USA|"UNITED STATES") echo "US"; return ;;
    UK|GB|"UNITED KINGDOM") echo "GB"; return ;;
    AE|UAE|"UNITED ARAB EMIRATES") echo "AE"; return ;;
    HK|HONGKONG) echo "HK"; return ;;
    TW|TAIWAN) echo "TW"; return ;;
    CN|CHINA) echo "CN"; return ;;
    DE|GERMANY) echo "DE"; return ;;
    FR|FRANCE) echo "FR"; return ;;
    IT|ITALY) echo "IT"; return ;;
    ES|SPAIN) echo "ES"; return ;;
    RU|RUSSIA) echo "RU"; return ;;
    SG|SINGAPORE) echo "SG"; return ;;
    TH|THAILAND) echo "TH"; return ;;
    VN|VIETNAM) echo "VN"; return ;;
    PH|PHILIPPINES) echo "PH"; return ;;
    ID|INDONESIA) echo "ID"; return ;;
    MY|MALAYSIA) echo "MY"; return ;;
    AU|AUSTRALIA) echo "AU"; return ;;
    NZ|NEWZEALAND) echo "NZ"; return ;;
    NL|NETHERLANDS) echo "NL"; return ;;
    BE|BELGIUM) echo "BE"; return ;;
    PL|POLAND) echo "PL"; return ;;
    CZ|CZECHIA|CZECH) echo "CZ"; return ;;
    CH|SWITZERLAND) echo "CH"; return ;;
    AT|AUSTRIA) echo "AT"; return ;;
    SE|SWEDEN) echo "SE"; return ;;
    NO|NORWAY) echo "NO"; return ;;
    FI|FINLAND) echo "FI"; return ;;
    PT|PORTUGAL) echo "PT"; return ;;
    RO|ROMANIA) echo "RO"; return ;;
    HU|HUNGARY) echo "HU"; return ;;
    SK|SLOVAKIA) echo "SK"; return ;;
    SI|SLOVENIA) echo "SI"; return ;;
    GR|GREECE) echo "GR"; return ;;
    IE|IRELAND) echo "IE"; return ;;
    MX|MEXICO) echo "MX"; return ;;
    CA|CANADA) echo "CA"; return ;;
    BR|BRAZIL) echo "BR"; return ;;
    AR|ARGENTINA) echo "AR"; return ;;
    CL|CHILE) echo "CL"; return ;;
    ZA|SOUTHAFRICA) echo "ZA"; return ;;
    *) echo "$x" ;;  # 其余直接返回（若已是 ISO2）
  esac
}

fetch_country_ips_primary() {
  # 主站：publicdnsserver.com
  local slug="$1" url="https://publicdnsserver.com/${slug}/"
  curl -sL --max-time 20 \
    -H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36' \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8' \
    -H 'accept-language: en-US,en;q=0.9' \
    "$url" | extract_ips
}

fetch_country_ips_fallback() {
  # 兜底：public-dns.info CSV，按 ISO2 过滤
  local iso2="$1" limit="${2:-$TOPN}"
  curl -sL --max-time 25 'https://public-dns.info/nameservers.csv' \
  | awk -F, -v iso="$iso2" 'NR>1 && toupper($2)==toupper(iso) {print $1}' \
  | awk '!seen[$0]++' \
  | head -n "$limit"
}

get_meta_json() {
  local ip="$1" cache="$META_CACHE_DIR/$ip.json"
  if [ -s "$cache" ]; then
    local now=$(date +%s) m=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    if [ $((now-m)) -lt 3600 ]; then cat "$cache"; return 0; fi
  fi
  local resp
  resp=$(curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,country,city,as,asname,org,isp,query")
  [ -n "$resp" ] || resp='{"status":"fail","country":"","city":"","as":"","asname":"","org":"","isp":"","query":""}'
  printf '%s' "$resp" >"$cache" 2>/dev/null || true
  sleep "$SLEEP_META"; printf '%s' "$resp"
}

json_get(){ echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }

parse_ping() {
  local out=$(cat)
  local loss=$(printf '%s\n' "$out" | grep -Eo '[0-9]+(\.[0-9]+)?% packet loss' | sed -E 's/%.*//')
  [ -z "$loss" ] && loss="100.0"
  local rtt=$(printf '%s\n' "$out" | grep -E 'min/avg/max' | tail -n1 | awk -F'=' '{print $2}' | awk '{print $1}')
  if [ -n "$rtt" ]; then IFS=/ read -r min avg max mdev <<<"$rtt"; else min="N/A"; avg="N/A"; max="N/A"; mdev="N/A"; fi
  printf '%s,%s,%s,%s,%s\n' "$loss" "$min" "$avg" "$max" "$mdev"
}

one_line(){ printf "\r%s" "$1"; command -v tput >/dev/null 2>&1 && tput el; }

# ---------------- 主流程 ----------------
read -rp "请输入英文国家名（如 Japan / United States / South Korea；或 ISO 两字母，如 JP）： " USER_REGION

SLUG=""   # 先定义，避免 set -u 报未绑定
SLUG=$(normalize_country_to_slug "$USER_REGION")
ISO2=$(normalize_to_iso2 "$USER_REGION")

declare -a TARGETS; declare -A seen

# 先尝试主站
while IFS= read -r ip; do
  [ -z "$ip" ] && continue
  if [[ "$ip" == *:* ]]; then TARGETS+=("$ip"); else is_public_ipv4 "$ip" && TARGETS+=("$ip"); fi
done < <(fetch_country_ips_primary "$SLUG")

# 如果主站抓不到，使用兜底 CSV
if [ "${#TARGETS[@]}" -eq 0 ]; then
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if [[ "$ip" == *:* ]]; then TARGETS+=("$ip"); else is_public_ipv4 "$ip" && TARGETS+=("$ip"); fi
  done < <(fetch_country_ips_fallback "$ISO2" "$TOPN")
fi

# 去重 + 截断
TMP=()
for ip in "${TARGETS[@]}"; do
  [ -z "${seen[$ip]+x}" ] && TMP+=("$ip") && seen["$ip"]=1
  [ "${#TMP[@]}" -ge "$TOPN" ] && break
done
TARGETS=("${TMP[@]}")

# 永远追加 Cloudflare / Google
for must in 1.1.1.1 8.8.8.8; do
  [ -z "${seen[$must]+x}" ] && TARGETS+=("$must") && seen["$must"]=1
done

N=${#TARGETS[@]}
printf "地区: %s（slug: %s）| 目标数: %d | 每个目标 ping 次数: %d\n" "$USER_REGION" "${SLUG:-}" "$N" "$COUNT"
echo "开始测试 ..."

declare -a RESULTS
idx=0
for ip in "${TARGETS[@]}"; do
  idx=$((idx+1)); pct=$((idx*100/N))
  one_line "进度[${idx}/${N} ${pct}%] #${idx} ${ip} | 正在测试..."
  if [[ "$ip" == *:* ]]; then
    out=$(ping -6 -n -c "$COUNT" -i 0.2 -w $((COUNT+4)) "$ip" 2>&1 || true)
  else
    out=$(ping    -n -c "$COUNT" -i 0.2 -w $((COUNT+4)) "$ip" 2>&1 || true)
  fi
  IFS=, read -r loss min avg max mdev <<<"$(printf '%s' "$out" | parse_ping)"

  meta=$(get_meta_json "$ip")
  country=$(json_get "$meta" country); [ -z "$country" ] && country="N/A"
  city=$(json_get "$meta" city); [ -z "$city" ] && city="N/A"
  asfull=$(json_get "$meta" as); asname=$(json_get "$meta" asname)
  org=$(json_get "$meta" org); isp=$(json_get "$meta" isp)
  asn=$(printf '%s' "$asfull" | sed -n 's/.*\(AS[0-9][0-9]*\).*/\1/p'); [ -z "$asn" ] && asn="N/A"
  company="$asname"; [ -z "$company" ] || [ "$company" = "N/A" ] && company="$org"
  [ -z "$company" ] || [ "$company" = "N/A" ] && company="$isp"; [ -z "$company" ] && company="N/A"

  one_line "进度[${idx}/${N} ${pct}%] #${idx} ${ip} | 丢包${loss}% 最小${min}ms 平均${avg}ms 最大${max}ms 抖动${mdev}ms"

  sortkey="$avg"; [[ "$sortkey" == "N/A" || -z "$sortkey" ]] && sortkey=999999999
  RESULTS+=("$sortkey\t$idx\t$ip\t$country/$city\t$asn\t$company\t$loss\t$min\t$avg\t$max\t$mdev")
done
echo; echo

printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
  "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动"
printf -- "-----------------------------------------------------------------------------------------------\n"

printf '%b\n' "${RESULTS[@]}" \
| sort -t$'\t' -k1,1n \
| cut -f2- \
| while IFS=$'\t' read -r idx0 ip region asn company loss min avg max mdev; do
    printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
      "$idx0" "$ip" "$region" "$asn" "$company" \
      "$(printf '%.1f%%' "${loss:-0}")" \
      "${min:-N/A}" "${avg:-N/A}" "${max:-N/A}" "${mdev:-N/A}"
  done
