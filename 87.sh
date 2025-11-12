#!/usr/bin/env bash
# vps-dns-ping.sh
# 按国家/地区抓取公共 DNS 列表，逐个 ping，最后按平均时延升序展示
# - 数据源：publicdnsserver.com（按国家页面 / 或 /download/<slug>.txt）
# - 额外固定目标：1.1.1.1 与 8.8.8.8
# - 元数据：ip-api.com（国家/地区/城市/ASN/公司）
# 依赖：curl，ping（支持 -6），awk，sed；若有 jq 会更准（可选）

# --------------------- 基本参数 ---------------------
PING_COUNT=${PING_COUNT:-10}        # 每个目标 ping 次数
TOPN=${TOPN:-30}                    # 每个地区最多抓取前 TOPN 个 DNS
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari'
COMMON_DNS=("1.1.1.1" "8.8.8.8")    # 固定加入
META_LANG=${META_LANG:-zh-CN}       # ip-api 返回语言
RESULTS_FILE="$(mktemp)"
META_CACHE_DIR="${TMPDIR:-/tmp}/dns_meta_cache"; mkdir -p "$META_CACHE_DIR"

# 颜色
C_RESET='\033[0m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_DIM='\033[2m'

# --------------------- 工具函数 ---------------------
die(){ echo -e "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }

extract_ips(){ # 从文本/HTML中提取 IP（v4+v6），去重
  grep -Eoi '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]{0,4}:){1,7}[0-9a-f]{0,4}' \
  | awk '!(seen[$0]++)'
}

normalize_slug(){ # 统一用户输入为站点的国家 slug
  local raw="$1" s
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  case "$s" in
    us|usa|unitedstates|unitedstatesofamerica) echo "unitedstates" ;;
    uk|gb|greatbritain|britain|unitedkingdom)  echo "unitedkingdom" ;;
    jp|jpn|japan)                              echo "japan" ;;
    cn|chn|china)                              echo "china" ;;
    kr|korea|southkorea|republicofkorea)       echo "southkorea" ;;
    hk|hongkong|hongkongsar)                   echo "hongkong" ;;
    tw|twn|taiwan)                             echo "taiwan" ;;
    sg|sgp|singapore)                          echo "singapore" ;;
    de|deu|germany)                            echo "germany" ;;
    fr|fra|france)                             echo "france" ;;
    it|ita|italy)                              echo "italy" ;;
    es|esp|spain)                              echo "spain" ;;
    au|aus|australia)                          echo "australia" ;;
    ca|can|canada)                             echo "canada" ;;
    ru|rus|russia)                             echo "russia" ;;
    br|bra|brazil)                             echo "brazil" ;;
    in|ind|india)                              echo "india" ;;
    id|idn|indonesia)                          echo "indonesia" ;;
    my|mys|malaysia)                           echo "malaysia" ;;
    th|tha|thailand)                           echo "thailand" ;;
    vn|vnm|vietnam)                            echo "vietnam" ;;
    ph|phl|philippines)                        echo "philippines" ;;
    ae|are|uae|unitedarabemirates)             echo "unitedarabemirates" ;;
    tr|tur|turkiye|turkey)                     echo "turkey" ;;
    se|swe|sweden)                             echo "sweden" ;;
    no|nor|norway)                             echo "norway" ;;
    dk|dnk|denmark)                            echo "denmark" ;;
    fi|fin|finland)                            echo "finland" ;;
    pl|pol|poland)                             echo "poland" ;;
    cz|cze|czech|czechrepublic)                echo "czechia" ;;
    sk|svk|slovakia)                           echo "slovakia" ;;
    at|aut|austria)                            echo "austria" ;;
    ch|che|switzerland)                        echo "switzerland" ;;
    mx|mex|mexico)                             echo "mexico" ;;
    ar|arg|argentina)                          echo "argentina" ;;
    cl|chl|chile)                              echo "chile" ;;
    nl|nld|netherlands)                        echo "netherlands" ;;
    za|zaf|southafrica)                        echo "southafrica" ;;
    *) echo "$s" ;;
  esac
}

fetch_dns_list(){ # 拉取指定国家的 DNS 列表（最多 TOPN）
  local slug="$1" tmp out url_txt url_html
  tmp="$(mktemp)"; out="$(mktemp)"
  url_txt="https://publicdnsserver.com/download/${slug}.txt"
  url_html="https://publicdnsserver.com/${slug}/"

  # 尝试下载 txt
  if curl -fsSL -A "$UA" "$url_txt" -o "$tmp" 2>/dev/null; then
    extract_ips <"$tmp" | head -n "$TOPN" >"$out"
  fi

  # 如果没提到 IP，再解析 HTML
  if [[ ! -s "$out" ]]; then
    curl -fsSL -A "$UA" "$url_html" -o "$tmp" 2>/dev/null || true
    extract_ips <"$tmp" | head -n "$TOPN" >"$out"
  fi

  if [[ ! -s "$out" ]]; then
    rm -f "$tmp" "$out"
    return 1
  fi

  cat "$out"
  rm -f "$tmp" "$out"
}

# 解析 ping 输出
parse_ping(){
  # 读取标准输入，输出：loss min avg max mdev（失败则 100 N/A N/A N/A N/A）
  awk '
  /packets transmitted/ {
    tx=$1; rx=$4;
    # 兼容不同实现的“丢包”字段位置
    for(i=1;i<=NF;i++){
      if($i ~ /%/){ sub("%","",$i); loss=$i }
    }
  }
  /packet loss/ { # busybox 风格
    for(i=1;i<=NF;i++){ if($i ~ /%/){ sub("%","",$i); loss=$i } }
  }
  /min\/avg\/max/ || /round-trip/ {
    # 形如：min/avg/max/mdev = a/b/c/d ms 或 min/avg/max/stddev = ...
    split($0, a, "="); g=a[length(a)]; gsub(/ms/,"",g); gsub(/ /,"",g)
    split(g, b, "/"); min=b[1]; avg=b[2]; max=b[3]; mdev=b[4];
  }
  END{
    if(loss=="" && rx!=""){ loss=(tx-rx)/tx*100 }
    if(loss=="") loss=100;
    if(min=="")  { print int(loss), "N/A","N/A","N/A","N/A" }
    else         { printf "%.1f %.3f %.3f %.3f %.3f\n", loss, min, avg, max, mdev }
  }'
}

# 获取 IP 元数据（国家/城市/ASN/公司），带缓存
get_meta(){
  local ip="$1" cache="${META_CACHE_DIR}/${ip}.txt"
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi

  local j
  j="$(curl -m 6 -s "http://ip-api.com/json/${ip}?lang=${META_LANG}&fields=status,country,regionName,city,as,org,isp,query")"
  if [[ -z "$j" ]]; then echo -e "N/A\tN/A\tN/A"; return 0; fi

  if have jq; then
    local country region city asn org isp
    country=$(jq -r '.country // "N/A"' <<<"$j")
    region=$(jq -r '.regionName // ""' <<<"$j")
    city=$(jq -r '.city // ""' <<<"$j")
    asn=$(jq -r '.as // "N/A"' <<<"$j")
    org=$(jq -r '.org // .isp // "N/A"' <<<"$j")
    [[ -n "$region$city" ]] && loc="${country}-${region}${city:+/${city}}" || loc="${country}"
    printf "%s\t%s\t%s\n" "${loc:-N/A}" "${asn:-N/A}" "${org:-N/A}" | tee "$cache" >/dev/null
  else
    # 粗糙 JSON 提取（无 jq）
    local country region city asn org
    country=$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
    region=$(printf '%s' "$j" | sed -n 's/.*"regionName":"\([^"]*\)".*/\1/p')
    city=$(printf '%s' "$j"   | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    asn=$(printf '%s' "$j"    | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')
    org=$(printf '%s' "$j"    | sed -n 's/.*"org":"\([^"]*\)".*/\1/p')
    [[ -z "$org" ]] && org=$(printf '%s' "$j" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
    local loc="$country"; [[ -n "$region$city" ]] && loc="${country}-${region}${city:+/${city}}"
    printf "%s\t%s\t%s\n" "${loc:-N/A}" "${asn:-N/A}" "${org:-N/A}" | tee "$cache" >/dev/null
  fi
}

color_loss(){
  local loss="$1"
  if [[ "$loss" == "N/A" ]]; then printf "%b%s%b" "$C_DIM" "$loss" "$C_RESET"; return; fi
  awk -v L="$loss" -v G="$C_GREEN" -v Y="$C_YELLOW" -v R="$C_RED" -v Z="$C_RESET" \
      'BEGIN{ if(L==0){c=G} else if(L<3){c=Y} else {c=R}; printf "%s%.1f%%%s", c, L, Z }'
}

color_avg(){
  local avg="$1"
  if [[ "$avg" == "N/A" ]]; then printf "%b%s%b" "$C_DIM" "$avg" "$C_RESET"; return; fi
  awk -v A="$avg" -v G="$C_GREEN" -v Y="$C_YELLOW" -v R="$C_RED" -v Z="$C_RESET" \
      'BEGIN{ if(A<20){c=G} else if(A<80){c=Y} else {c=R}; printf "%s%.3f%s", c, A, Z }'
}

do_ping(){
  local ip="$1"
  local c="${PING_COUNT}"
  local cmd="ping"
  [[ "$ip" == *:* ]] && cmd="ping -6"
  # 兼容不同实现：-W 单次超时(秒)；-i 间隔
  $cmd -c "$c" -W 1 -i 0.2 "$ip" 2>/dev/null | parse_ping
}

# --------------------- 主流程 ---------------------
have curl || die "需要安装 curl"
have ping || die "需要安装 ping"

read -rp "请输入要测试的国家/地区（可以写国家名，如 Japan，也可以写 ISO 两字母，如 JP）： " REGION
[[ -z "${REGION// }" ]] && die "未输入地区"

SLUG=$(normalize_slug "$REGION")
# 拉取 DNS 列表
MAP_IPS="$(fetch_dns_list "$SLUG" || true)"

# 拼上固定目标
for x in "${COMMON_DNS[@]}"; do MAP_IPS="${MAP_IPS}"$'\n'"$x"; done

# 去重 & 截断
TARGETS=()
while IFS= read -r ip; do [[ -n "$ip" ]] && TARGETS+=("$ip"); done < <(printf '%s\n' "$MAP_IPS" | awk 'NF{if(!seen[$0]++){print}}' | head -n "$TOPN")

TOTAL=${#TARGETS[@]}
[[ "$TOTAL" -eq 0 ]] && die "无法为 slug=${SLUG} 解析到任何 DNS IP，请更换地区稍后再试。"

echo -e "地区: ${C_CYAN}${REGION}${C_RESET}（slug: ${C_CYAN}${SLUG}${C_RESET}）| 目标数: ${C_GREEN}${TOTAL}${C_RESET} | 每个目标 ping 次数: ${C_GREEN}${PING_COUNT}${C_RESET}"
echo -n "将测试的目标："
printf "%s " "${TARGETS[@]}"
echo
echo "开始测试 ..."

# 逐个测试并记录：orig_idx ip loss min avg max mdev  location  asn  org
idx=0
for ip in "${TARGETS[@]}"; do
  idx=$((idx+1))
  pct=$(( idx*100 / TOTAL ))
  printf "进度: [%2d/%d | %3d%%] #%d   正在测试: %s\r" "$idx" "$TOTAL" "$pct" "$idx" "$ip"
  read -r loss min avg max mdev < <(do_ping "$ip")
  # 元数据（带缓存）
  read -r LOC ASN ORG < <(get_meta "$ip")
  printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
         "$idx" "$ip" "${loss}" "${min}" "${avg}" "${max}" "${mdev}" "$LOC" "$ASN" "$ORG" \
         >> "$RESULTS_FILE"
done
echo

# 排序（按 avg 升序；N/A 视为极大）
SORTED="$(awk -F'\t' '
function key(v){ return (v=="N/A" ? 1e12 : v)+0 }
{ printf "%015.3f\t%s\n", key($5), $0 }
' "$RESULTS_FILE" | sort -n | cut -f2- )"

# --------------------- 展示结果 ---------------------
# 表头
printf "%-6s %-18s %-24s %-16s %-28s %-6s %-10s %-10s %-10s %-6s\n" \
  "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动"
printf '%s\n' "-----------------------------------------------------------------------------------------------\
---------------------------------------------------------"

# 行输出（保持“编号”为测试时原编号）
while IFS=$'\t' read -r ORIG IP LOSS MIN AVG MAX MDEV LOC ASN ORG; do
  # 着色字段
  LOSS_COL="$(color_loss "$LOSS")"
  AVG_COL="$(color_avg "$AVG")"
  # 其它字段格式化
  [[ "$MIN" == "N/A" ]] && MINF="$MIN" || MINF=$(printf "%.3f" "$MIN")
  [[ "$MAX" == "N/A" ]] && MAXF="$MAX" || MAXF=$(printf "%.3f" "$MAX")
  [[ "$MDEV" == "N/A" ]] && MDEVF="$MDEV" || MDEVF=$(printf "%.3f" "$MDEV")
  printf "%-6s %-18s %-24s %-16s %-28s %s %-10s %s %-10s %-6s\n" \
    "#${ORIG}" "$IP" "${LOC:-N/A}" "${ASN:-N/A}" "${ORG:-N/A}" \
    "$LOSS_COL" "$MINF" "$AVG_COL" "$MAXF" "$MDEVF"
done <<< "$SORTED"

# 清理
rm -f "$RESULTS_FILE"
