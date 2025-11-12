#!/usr/bin/env bash
# DNS 公共服务器连通性测试（按国家/地区抓取）
# - 从 publicdnsserver.com/<country-slug>/ 解析 IP
# - 过滤无效/私网 IPv4，保留 IPv6
# - ping 统计（丢包/最小/平均/最大/抖动）
# - 查询地区/ASN/公司（ip-api.com，带简单缓存）
# - 排序按平均延迟升序；显示测试时的原始编号

set -u

COUNT=${COUNT:-10}        # 每个目标 ping 次数
TOPN=${TOPN:-30}          # 每个国家抓取的最多目标数
SLEEP_META=${SLEEP_META:-0.15}  # 每次元数据查询的间隔（防限速）
META_CACHE_DIR="${META_CACHE_DIR:-/tmp/dns_meta_cache}"
mkdir -p "$META_CACHE_DIR" >/dev/null 2>&1 || true

# ===== 工具函数 =====

# 严格提取合法 IP（IPv4 每段 0-255；IPv6 粗略校验）
extract_ips() {
  # 去掉 HTML 标签，避免数字黏连
  sed -E 's/<[^>]+>/ /g' \
  | tr -c '0-9A-Fa-f:.' '\n' \
  | grep -E '(^([0-9]{1,3}\.){3}[0-9]{1,3}$)|(^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$)' \
  | awk '!seen[$0]++' \
  | awk -F. '
      $0 ~ /:/ { print; next }       # IPv6 放行
      NF==4 {
        ok=1
        for(i=1;i<=4;i++){
          if($i !~ /^[0-9]+$/ || $i<0 || $i>255){ ok=0; break }
        }
        if(ok) print $0
      }
    '
}

# 过滤掉私网/保留网段（仅 IPv4）
is_public_ipv4() {
  local ip="$1"; IFS=. read -r a b c d <<<"$ip" || return 1
  if ((a==10)) || ((a==127)) || ((a==192 && b==168)) || ((a==169 && b==254)) \
     || ((a==172 && b>=16 && b<=31)) || ((a==100 && b>=64 && b<=127)) \
     || ((a==0)) || ((a>=224)); then
    return 1
  fi
  return 0
}

# ISO/常见缩写 -> 站点 slug
normalize_country_to_slug() {
  local raw="$1"
  local x
  x=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  x=$(printf '%s' "$x" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

  # 去空格/横线，做成 slug 候选
  local compact
  compact=$(printf '%s' "$x" | sed -E 's/[^a-z0-9]+//g')

  # 一些常见 ISO/别名映射
  case "$compact" in
    jp) echo "japan"; return ;;
    kr|rok) echo "southkorea"; return ;;
    us|usa) echo "unitedstates"; return ;;
    uk|gb) echo "unitedkingdom"; return ;;
    ae|uae) echo "unitedarabemirates"; return ;;
    hk) echo "hongkong"; return ;;
    tw) echo "taiwan"; return ;;
    cn) echo "china"; return ;;
    de) echo "germany"; return ;;
    fr) echo "france"; return ;;
    it) echo "italy"; return ;;
    es) echo "spain"; return ;;
    ru) echo "russia"; return ;;
    sg) echo "singapore"; return ;;
    th) echo "thailand"; return ;;
    vn) echo "vietnam"; return ;;
    ph) echo "philippines"; return ;;
    id) echo "indonesia"; return ;;
    my) echo "malaysia"; return ;;
    au) echo "australia"; return ;;
    nz) echo "newzealand"; return ;;
    nl) echo "netherlands"; return ;;
    be) echo "belgium"; return ;;
    pl) echo "poland"; return ;;
    cz) echo "czechia"; return ;;
    ch) echo "switzerland"; return ;;
    at) echo "austria"; return ;;
    se) echo "sweden"; return ;;
    no) echo "norway"; return ;;
    fi) echo "finland"; return ;;
    pt) echo "portugal"; return ;;
    ro) echo "romania"; return ;;
    hu) echo "hungary"; return ;;
    sk) echo "slovakia"; return ;;
    si) echo "slovenia"; return ;;
    gr) echo "greece"; return ;;
    ie) echo "ireland"; return ;;
    mx) echo "mexico"; return ;;
    ca) echo "canada"; return ;;
    br) echo "brazil"; return ;;
    ar) echo "argentina"; return ;;
    cl) echo "chile"; return ;;
    za) echo "southafrica"; return ;;
  esac

  # 直接用英文国名，也处理空格
  x=$(printf '%s' "$x" | sed -E 's/[[:space:]]+//g')
  echo "$x"
}

# 抓取某国家页面，提取 IP
fetch_country_ips() {
  local slug="$1"
  local url="https://publicdnsserver.com/${slug}/"
  local html
  html=$(curl -sL --max-time 15 "$url" || true)
  if [ -z "$html" ]; then
    echo ""
    return 0
  fi
  printf '%s' "$html" | extract_ips
}

# 取元数据（带缓存）：country / city / ASN / company
get_meta_json() {
  local ip="$1"
  local cache="$META_CACHE_DIR/$ip.json"
  local now epoch mtime age

  if [ -s "$cache" ]; then
    # 简单一小时缓存
    epoch=$(date +%s)
    mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    age=$((epoch - mtime))
    if [ "$age" -lt 3600 ]; then
      cat "$cache"
      return 0
    fi
  fi

  local resp
  resp=$(curl -s --max-time 5 "http://ip-api.com/json/$ip?fields=status,message,country,city,as,asname,org,isp,query")
  if [ -n "$resp" ]; then
    printf '%s' "$resp" >"$cache" 2>/dev/null || true
    printf '%s' "$resp"
  else
    # 返回最小结构，避免后续解析报错
    printf '{"status":"fail","country":"","city":"","as":"","asname":"","org":"","isp":"","query":"%s"}' "$ip"
  fi
  sleep "$SLEEP_META"
}

# 从 JSON 简单提取字段
json_get() {
  # 用 sed 粗提（避免依赖 jq）
  # 使用占位替换处理 \"
  echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

# 解析 ping 输出（兼容 Linux 常见格式）
parse_ping() {
  # 读取标准输入，输出：loss,min,avg,max,mdev（其中 loss 百分比数字）
  local out
  out=$(cat)

  local loss min avg max mdev
  loss=$(printf '%s\n' "$out" | grep -Eo '[0-9]+(\.[0-9]+)?% packet loss' | sed -E 's/%.*//')
  [ -z "$loss" ] && loss="100.0"

  # rtt 行可能是 rtt 或 round-trip
  local rtt
  rtt=$(printf '%s\n' "$out" | grep -E 'min/avg/max' | tail -n1 | awk -F'=' '{print $2}' | awk '{print $1}')
  if [ -n "$rtt" ]; then
    IFS=/ read -r min avg max mdev <<<"$rtt"
  else
    min="N/A"; avg="N/A"; max="N/A"; mdev="N/A"
  fi

  printf '%s,%s,%s,%s,%s\n' "$loss" "$min" "$avg" "$max" "$mdev"
}

# ===== 主流程 =====

read -rp "请输入英文国家名（如 Japan / United States / South Korea；或 ISO 两字母，如 JP）： " USER_REGION
SLUG=$(normalize_country_to_slug "$USER_REGION")

# 抓取 IP 列表并做合法/公网过滤
MAP_IPS_RAW=$(fetch_country_ips "$SLUG")
TARGETS=()

while IFS= read -r ip; do
  [ -z "$ip" ] && continue
  if [[ "$ip" == *:* ]]; then
    # IPv6：直接加入
    TARGETS+=("$ip")
  else
    if is_public_ipv4 "$ip"; then
      TARGETS+=("$ip")
    fi
  fi
done < <(printf '%s\n' "$MAP_IPS_RAW" | awk 'NF{if(!seen[$0]++){print}}')

# 限制数量并追加 1.1.1.1 / 8.8.8.8
# 只打印解析后的 IP，不再打印 HTML
# 目标列表去重
TMP_LIST=()
declare -A seen
for ip in "${TARGETS[@]}"; do
  if [ -z "${seen[$ip]+x}" ]; then
    TMP_LIST+=("$ip"); seen["$ip"]=1
  fi
  [ "${#TMP_LIST[@]}" -ge "$TOPN" ] && break
done
TARGETS=("${TMP_LIST[@]}")

# 始终包含 Cloudflare/Google
for must in 1.1.1.1 8.8.8.8; do
  if [ -z "${seen[$must]+x}" ]; then
    TARGETS+=("$must"); seen["$must"]=1
  fi
done

N=${#TARGETS[@]}
printf "地区: %s（slug: %s）| 目标数: %d | 每个目标 ping 次数: %d\n" "$USER_REGION" "$SLUG" "$N" "$COUNT"
printf "将测试的目标：%s\n" "$(printf '%s ' "${TARGETS[@]}")"
echo "开始测试 ..."

# 测试并收集结果：记录原始编号（测试顺序）
RESULTS=()
idx=0
for ip in "${TARGETS[@]}"; do
  idx=$((idx+1))
  pct=$((idx*100/N))
  printf "进度: [%d/%d | %3d%%] #%d   正在测试: %s\r" "$idx" "$N" "$pct" "$idx" "$ip"

  # 选择 ping 命令
  if [[ "$ip" == *:* ]]; then
    # IPv6
    out=$(ping -6 -n -c "$COUNT" -i 0.2 -w $((COUNT+4)) "$ip" 2>&1 || true)
  else
    out=$(ping    -n -c "$COUNT" -i 0.2 -w $((COUNT+4)) "$ip" 2>&1 || true)
  fi

  stats=$(printf '%s' "$out" | parse_ping)
  IFS=, read -r loss min avg max mdev <<<"$stats"

  # 查询元数据（缓存）
  meta=$(get_meta_json "$ip")
  country=$(json_get "$meta" country); [ -z "$country" ] && country="N/A"
  city=$(json_get "$meta" city);       [ -z "$city" ] && city="N/A"
  asfull=$(json_get "$meta" as);       [ -z "$asfull" ] && asfull="N/A"
  asname=$(json_get "$meta" asname);   [ -z "$asname" ] && asname="N/A"
  org=$(json_get "$meta" org)
  isp=$(json_get "$meta" isp)

  # ASN 号提取为 ASXXXX
  asn=$(printf '%s' "$asfull" | sed -n 's/.*\(AS[0-9][0-9]*\).*/\1/p')
  [ -z "$asn" ] && asn="N/A"

  # 公司优先 asname，其次 org/isp
  company="$asname"
  [ -z "$company" ] || [ "$company" = "N/A" ] && company="$org"
  [ -z "$company" ] || [ "$company" = "N/A" ] && company="$isp"
  [ -z "$company" ] && company="N/A"

  # 进度行（单行简报）
  printf "进度: [%d/%d | %3d%%] #%d   正在测试: %-39s | 丢包 %s%% | 最小 %sms | 平均 %sms | 最大 %sms | 抖动 %sms\n" \
         "$idx" "$N" "$pct" "$idx" "$ip" "$loss" "$min" "$avg" "$max" "$mdev"

  # 结果记录（制表符分隔；最后附加排序键）
  sortkey="$avg"
  [[ "$sortkey" == "N/A" || -z "$sortkey" ]] && sortkey=999999999
  RESULTS+=("$sortkey\t$idx\t$ip\t$country/$city\t$asn\t$company\t$loss\t$min\t$avg\t$max\t$mdev")
done
echo

# 输出表格（按平均延迟排序，但“编号”为测试时原始编号）
# 标题
printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
  "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动"

printf -- "-----------------------------------------------------------------------------------------------\n"

# 排序并打印；去掉第 1 列排序键
printf '%b\n' "${RESULTS[@]}" \
| sort -t$'\t' -k1,1n \
| cut -f2- \
| while IFS=$'\t' read -r idx0 ip region asn company loss min avg max mdev; do
    printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
      "$idx0" "$ip" "$region" "$asn" "$company" \
      "$(printf '%.1f%%' "${loss:-0}")" \
      "${min:-N/A}" "${avg:-N/A}" "${max:-N/A}" "${mdev:-N/A}"
  done
