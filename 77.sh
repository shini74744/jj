#!/usr/bin/env bash
# dns_ping_check.sh
# 批量 ping DNS 服务器，输出丢包/RTT，并按 "丢包率 -> 平均延迟" 排序
# 用法：
#   ./dns_ping_check.sh [list_file] [count] [csv]
#   list_file: 可选，包含要测试的 DNS（每行一个 IP/域名）。缺省用内置列表
#   count    : 可选，单目标 ping 次数（默认 10）
#   csv      : 可选，传入 "csv" 则另存结果为 dns_ping_results.csv

set -euo pipefail

LIST_FILE="${1:-}"
COUNT="${2:-10}"
CSV_OUT="${3:-}"

# 内置常见公共 DNS（Anycast，通常就近到日本）
builtin_dns=(
  1.1.1.1          # Cloudflare
  1.0.0.1
  8.8.8.8          # Google
  8.8.4.4
  9.9.9.9          # Quad9
  149.112.112.112
  208.67.222.222   # OpenDNS
  208.67.220.220
  94.140.14.14     # AdGuard
  94.140.15.15
  64.6.64.6        # Verisign
  64.6.65.6
  8.26.56.26       # Comodo Secure
  8.20.247.20
)

# 读取目标列表
targets=()
if [[ -n "$LIST_FILE" ]]; then
  if [[ ! -f "$LIST_FILE" ]]; then
    echo "未找到列表文件：$LIST_FILE"
    exit 1
  fi
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo -n "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] && targets+=("$line")
  done < "$LIST_FILE"
else
  targets=("${builtin_dns[@]}")
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "目标列表为空。"
  exit 1
fi

# 检查 ping 是否可用
if ! command -v ping >/dev/null 2>&1; then
  echo "未找到 ping 命令，请先安装（iputils-ping 或 busybox 自带 ping）。"
  exit 1
fi

# 临时结果
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
: >"$TMP"

echo "目标数: ${#targets[@]} | 每个目标 ping 次数: $COUNT"
echo "开始测试 ..."

# 检测 ping 风格（GNU iputils vs BSD/BusyBox），用于选择参数
PING_STYLE="GNU"  # 先假设 GNU
if ping -h 2>&1 | grep -qi 'busybox'; then
  PING_STYLE="BUSYBOX"
elif ping -h 2>&1 | grep -qi 'usage:' | grep -qi 'bsd'; then
  PING_STYLE="BSD"
fi

# 执行一次 ping 并解析输出
ping_once() {
  local host="$1"
  local count="$2"
  local out rc

  case "$PING_STYLE" in
    GNU)
      # -c 次数, -W per-packet 超时(秒), -n 不做反查
      out="$(ping -n -c "$count" -W 2 "$host" 2>&1)" || true
      ;;
    BUSYBOX)
      # busybox: -c 次数, -W 超时(秒), -w 全局超时
      out="$(ping -n -c "$count" -W 2 -w $((count*3)) "$host" 2>&1)" || true
      ;;
    BSD)
      # macOS/某些BSD：-c 次数, -t TTL（没有统一的 per-packet 超时，只能靠整体超时控制）
      # 这里统一用 -c，若超时由系统控制
      out="$(ping -n -c "$count" "$host" 2>&1)" || true
      ;;
    *)
      out="$(ping -n -c "$count" -W 2 "$host" 2>&1)" || true
      ;;
  esac

  # 丢包
  local loss
  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | sed -e 's/packet loss//' -e 's/ //g')"
  [[ -z "$loss" ]] && loss="$(echo "$out" | sed -n 's/.* \([0-9.]\+%\) packet loss.*/\1/p' | head -n1)"
  [[ -z "$loss" ]] && loss="100%"

  # RTT
  local rline rmin ravg rmax rdev
  rline="$(echo "$out" | grep -E 'rtt|min/avg/max|round-tr
