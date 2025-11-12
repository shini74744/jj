#!/usr/bin/env bash
# DNS 连通性测试（按国家抓取）——单行动态进度版
set -u

COUNT=${COUNT:-10}              # 每目标 ping 次数
TOPN=${TOPN:-30}                # 每国家抓取最多目标
SLEEP_META=${SLEEP_META:-0.15}  # ASN/公司查询间隔（防限速）
META_CACHE_DIR="${META_CACHE_DIR:-/tmp/dns_meta_cache}"
mkdir -p "$META_CACHE_DIR" >/dev/null 2>&1 || true

# ---------- 工具函数 ----------
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

fetch_country_ips() {
  local slug="$1" url="https://publicdnsserver.com/${slug}/"
  curl -sL --max-time 15 "$url" | extract_ips
}

get_meta_json() {
  local ip="$1" cache="$META_CACHE_DIR/$ip.json"
  if [ -s "$cache" ]; then
    local now=$(date +%s) m=$(stat -c %Y "$cache"
