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
  case "$co
