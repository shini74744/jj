#!/usr/bin/env bash

set -u
set -o pipefail

COUNT=${COUNT:-10}
TOPN=${TOPN:-30}
SLEEP_META=${SLEEP_META:-0.15}
META_CACHE_DIR="${META_CACHE_DIR:-/tmp/dns_meta_cache}"
mkdir -p "$META_CACHE_DIR" >/dev/null 2>&1 || true

# deps
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 1; }; }
require_cmd curl
require_cmd awk
require_cmd sed
require_cmd tr
require_cmd grep
require_cmd ping

PING_BIN="ping"
PING6_BIN="ping -6"
if command -v ping6 >/dev/null 2>&1; then
  PING6_BIN="ping6"
fi

# color banner (red)
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  RED=""
  RESET=""
fi
printf "%b\n\n" "${RED}作者-DadaGi大大怪  |  赞助探针地址：shli.io${RESET}"

# extract valid IPs (IPv4 strict / IPv6 loose)
extract_ips() {
  sed -E 's/<[^>]+>/ /g' \
  | tr -c '0-9A-Fa-f:.' '\n' \
  | grep -E '(^([0-9]{1,3}\.){3}[0-9]{1,3}$)|(^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$)' \
  | awk '!seen[$0]++' \
  | awk -F. '
      $0 ~ /:/ { print; next }
      NF==4 {
        ok=1
        for(i=1;i<=4;i++){
          if($i !~ /^[0-9]+$/ || $i<0 || $i>255){ ok=0; break }
        }
        if(ok) print $0
      }
    '
}

# filter private/reserved IPv4
is_public_ipv4() {
  local ip="$1"; IFS=. read -r a b c d <<<"$ip" || return 1
  if ((a==10)) || ((a==127)) || ((a==192 && b==168)) || ((a==169 && b==254)) \
     || ((a==172 && b>=16 && b<=31)) || ((a==100 && b>=64 && b<=127)) \
     || ((a==0)) || ((a>=224)); then
    return 1
  fi
  return 0
}

# normalize country to slug
normalize_country_to_slug() {
  local raw="$1"
  local x compact
  x=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  x=$(printf '%s' "$x" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  compact=$(printf '%s' "$x" | sed -E 's/[^a-z0-9]+//g')
  case "$compact" in
    jp) echo "japan"; return;;
    kr|rok) echo "southkorea"; return;;
    us|usa) echo "unitedstates"; return;;
    uk|gb) echo "unitedkingdom"; return;;
    ae|uae) echo "unitedarabemirates"; return;;
    hk) echo "hongkong"; return;;
    tw) echo "taiwan"; return;;
    cn) echo "china"; return;;
    de) echo "germany"; return;;
    fr) echo "france"; return;;
    it) echo "italy"; return;;
    es) echo "spain"; return;;
    ru) echo "russia"; return;;
    sg) echo "singapore"; return;;
    th) echo "thailand"; return;;
    vn) echo "vietnam"; return;;
    ph) echo "philippines"; return;;
    id) echo "indonesia"; return;;
    my) echo "malaysia"; return;;
    au) echo "australia"; return;;
    nz) echo "newzealand"; return;;
    nl) echo "netherlands"; return;;
    be) echo "belgium"; return;;
    pl) echo "poland"; return;;
    cz) echo "czechia"; return;;
    ch) echo "switzerland"; return;;
    at) echo "austria"; return;;
    se) echo "sweden"; return;;
    no) echo "norway"; return;;
    fi) echo "finland"; return;;
    pt) echo "portugal"; return;;
    ro) echo "romania"; return;;
    hu) echo "hungary"; return;;
    sk) echo "slovakia"; return;;
    si) echo "slovenia"; return;;
    gr) echo "greece"; return;;
    ie) echo "ireland"; return;;
    mx) echo "mexico"; return;;
    ca) echo "canada"; return;;
    br) echo "brazil"; return;;
    ar) echo "argentina"; return;;
    cl) echo "chile"; return;;
    za) echo "southafrica"; return;;
  esac
  x=$(printf '%s' "$x" | sed -E 's/[[:space:]]+//g')
  echo "$x"
}

# fetch IPs from publicdnsserver page
fetch_country_ips() {
  local slug="$1"
  local url="https://publicdnsserver.com/${slug}/"
  local html
  html=$(curl -sL --max-time 15 "$url" || true)
  [ -z "$html" ] && { echo ""; return 0; }
  printf '%s' "$html" | extract_ips
}

# metadata (ip-api) with 1h cache
get_meta_json() {
  local ip="$1"
  local cache="$META_CACHE_DIR/$ip.json"
  local epoch mtime age
  if [ -s "$cache" ]; then
    epoch=$(date +%s)
    if mtime=$(stat -c %Y "$cache" 2>/dev/null); then
      age=$((epoch - mtime))
      if [ "$age" -lt 3600 ]; then
        cat "$cache"; return 0
      fi
    fi
  fi
  local resp
  resp=$(curl -s --max-time 5 "http://ip-api.com/json/$ip?fields=status,message,country,city,as,asname,org,isp,query")
  if [ -n "$resp" ]; then
    printf '%s' "$resp" >"$cache" 2>/dev/null || true
    printf '%s' "$resp"
  else
    printf '{"status":"fail","country":"","city":"","as":"","asname":"","org":"","isp":"","query":"%s"}' "$ip"
  fi
  sleep "$SLEEP_META"
}

# poor-man's json getter (no jq)
json_get() {
  echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

# parse ping output (returns: loss,min,avg,max,mdev)
parse_ping() {
  local out; out=$(cat)
  local loss min avg max mdev rtt
  loss=$(printf '%s\n' "$out" | LC_ALL=C grep -Eo '[0-9]+(\.[0-9]+)?% packet loss' | sed -E 's/%.*//')
  [ -z "$loss" ] && loss="100.0"
  rtt=$(printf '%s\n' "$out" | LC_ALL=C grep -E 'min/avg/max' | tail -n1 | awk -F'=' '{print $2}' | awk '{pri_
