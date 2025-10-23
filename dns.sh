#!/bin/bash
# 网络延迟一键检测工具 - Interactive Network Latency Tester
# Version: 2.1-patch (2025-10-23)

# 检查bash版本，关联数组需要bash 4.0+
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "错误: 此脚本需要 bash 4.0 或更高版本"
    echo "当前版本: $BASH_VERSION"
    echo ""
    echo "macOS用户请安装新版bash:"
    echo "  brew install bash"
    echo "  然后使用新版bash运行: /opt/homebrew/bin/bash latency.sh"
    echo ""
    echo "或者在脚本开头指定新版bash:"
    echo "  #!/opt/homebrew/bin/bash"
    exit 1
fi

# set -eo pipefail  # 调试时可注释

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 获取毫秒时间戳（跨平台）
get_timestamp_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time() * 1000))"
    elif command -v python >/dev/null 2>&1; then
        python -c "import time; print(int(time.time() * 1000))"
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo $(( $(date +%s) * 1000 ))
    else
        local ns=$(date +%s%N 2>/dev/null)
        if [[ "$ns" =~ N$ ]]; then
            echo $(( $(date +%s) * 1000 ))
        else
            echo $(( ns / 1000000 ))
        fi
    fi
}

# 计算字符串显示宽度（考虑中文字符占2个位置）
display_width() {
    local str="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys; s='$str'; print(sum(2 if ord(c) > 127 else 1 for c in s))"
    else
        # 简易估算：UTF-8 在纯 Bash 下不完全准确，但尽量避免过宽
        local len=${#str}
        local width=0
        local i
        for ((i=0; i<len; i++)); do
            local ch="${str:$i:1}"
            # 粗略：非 ASCII 视为宽字符
            if [[ $(printf '%d' "'$ch" 2>/dev/null) -gt 127 ]]; then
                width=$((width + 2))
            else
                width=$((width + 1))
            fi
        done
        echo "$width"
    fi
}

# 打印对齐的行
print_aligned_row() {
    local rank="$1"
    local col1="$2"  # DNS名称
    local col2="$3"  # IP地址
    local col3="$4"  # 延迟/时间
    local col4="$5"  # 状态（带颜色）

    local col1_display=$(display_width "$col1")
    local col1_target=15
    local padding1=$((col1_target - col1_display))
    (( padding1 < 0 )) && padding1=0

    local col2_display=$(display_width "$col2")
    local col2_target=20
    local padding2=$((col2_target - col2_display))
    (( padding2 < 0 )) && padding2=0

    printf "%2d. %s%*s %s%*s %-12s" "$rank" "$col1" "$padding1" "" "$col2" "$padding2" "" "$col3"
    if [[ -n "$col4" ]]; then
        echo -e " $col4"
    else
        echo ""
    fi
}

# 配置变量
PING_COUNT=10
DOWNLOAD_TEST_SIZE="1M"
DNS_TEST_DOMAIN="google.com"
IP_VERSION=""                  # 4/6/auto
SELECTED_DNS_SERVER=""         # 解析用的 DNS
SELECTED_DNS_NAME=""

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ -n "$WSL_DISTRO_NAME" ]]; then
        OS_TYPE="wsl"
    else
        OS_TYPE="unknown"
    fi
}

# 获取 ping 命令
get_ping_cmd() {
    local version=${1:-"4"}
    if [[ "$version" == "6" ]]; then
        if command -v ping6 >/dev/null 2>&1; then
            echo "ping6"
        elif [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -6"
        elif [[ "$OS_TYPE" == "macos" ]]; then
            echo "ping6"
        else
            echo "ping -6"
        fi
    else
        if [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -4"
        else
            echo "ping"
        fi
    fi
}

# 获取 ping 间隔
get_ping_interval() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        echo ""
    else
        echo "-i 0.5"
    fi
}

# 获取 timeout 命令
get_timeout_cmd() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        if command -v gtimeout >/dev/null 2>&1; then
            echo "gtimeout"
        else
            echo ""
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            echo "timeout"
        else
            echo ""
        fi
    fi
}

detect_os

# 批量 fping（备用函数，当前主逻辑用 show_fping_results）
test_batch_latency_fping() {
    local hosts=("$@")
    local temp_file="/tmp/fping_hosts_$$"
    local temp_results="/tmp/fping_results_$$"

    printf '%s\n' "${hosts[@]}" > "$temp_file"

    local fping_cmd=""
    if command -v fping >/dev/null 2>&1; then
        if [[ "$IP_VERSION" == "6" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
        elif [[ "$IP_VERSION" == "4" ]]; then
            fping_cmd="fping -4"
        else
            fping_cmd="fping"
        fi
        $fping_cmd -c $PING_COUNT -q -f "$temp_file" 2>"$temp_results" || true
    else
        while IFS= read -r host; do
            local ping_cmd=$(get_ping_cmd "$IP_VERSION")
            local interval=$(get_ping_interval)
            local timeout_cmd=$(get_timeout_cmd)

            local ping_result
            if [[ -n "$timeout_cmd" ]]; then
                if [[ -n "$interval" ]]; then
                    ping_result=$($timeout_cmd 10 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "timeout")
                else
                    ping_result=$($timeout_cmd 10 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "timeout")
                fi
            else
                if [[ -n "$interval" ]]; then
                    ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "timeout")
                else
                    ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "timeout")
                fi
            fi
            if [[ "$ping_result" != "timeout" ]]; then
                local avg_latency=$(echo "$ping_result" | grep -o 'min/avg/max[^=]*= [0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'=' -f2 | cut -d'/' -f2 || echo "timeout")
                echo "$host : $avg_latency ms" >> "$temp_results"
            else
                echo "$host : timeout" >> "$temp_results"
            fi
        done < "$temp_file"
    fi

    rm -f "$temp_file"
    echo "$temp_results"
}

# 使用 fping 显示快速延迟测试
show_fping_results() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}📡 快速Ping延迟测试 (使用fping批量测试)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

    local hosts=()
    local valid_hosts=()
    for service in "${!FULL_SITES[@]}"; do
        local host="${FULL_SITES[$service]}"
        local clean_host="${host#./}"
        if [[ -n "$host" && "$host" != "latency.sh" && "$clean_host" != *".sh" && "$host" != ./* && "$host" != /* && "$host" =~ ^[a-zA-Z0-9].*$ ]]; then
            hosts+=("$host")
            valid_hosts+=("$service|$host")
        fi
    done

    local temp_file="/tmp/fping_hosts_$$"
    local temp_results="/tmp/fping_results_$$"
    rm -f "$temp_file" "$temp_results" 2>/dev/null

    local fping_cmd=""

    if [[ "$IP_VERSION" == "6" ]]; then
        echo -e "(IPv6优先) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."

        local ipv6_hosts=()
        local ipv4_hosts=()

        echo -n "检测IPv6支持..."
        for host in "${hosts[@]}"; do
            if command -v dig >/dev/null 2>&1; then
                if dig +short +time=1 +tries=1 AAAA "$host" 2>/dev/null | grep -q ":" ; then
                    ipv6_hosts+=("$host")
                else
                    ipv4_hosts+=("$host")
                fi
            elif command -v nslookup >/dev/null 2>&1; then
                if nslookup -type=AAAA "$host" 2>/dev/null | grep -q "Address: .*:" ; then
                    ipv6_hosts+=("$host")
                else
                    ipv4_hosts+=("$host")
                fi
            else
                # 探测不到解析工具时，尝试直接 -6 ping 探活
                if ping -6 -c1 -W1 "$host" >/dev/null 2>&1; then
                    ipv6_hosts+=("$host")
                else
                    ipv4_hosts+=("$host")
                fi
            fi
        done
        echo " 完成 (IPv6: ${#ipv6_hosts[@]}个, IPv4: ${#ipv4_hosts[@]}个)"

        if [[ ${#ipv6_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv6主机..."
            printf '%s\n' "${ipv6_hosts[@]}" > "${temp_file}_v6"
            if command -v fping6 >/dev/null 2>&1; then
                fping6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            else
                fping -6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            fi
            echo " 完成"
        fi
        if [[ ${#ipv4_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv4主机 (fallback)..."
            printf '%s\n' "${ipv4_hosts[@]}" > "${temp_file}_v4"
            fping -4 -c 10 -q -f "${temp_file}_v4" 2>"${temp_results}_v4" || true
            echo " 完成"
        fi

        cat "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null > "$temp_results" || true
        rm -f "${temp_file}_v6" "${temp_file}_v4" "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null

    elif [[ "$IP_VERSION" == "4" ]]; then
        echo -e "(IPv4) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping -4"
        printf '%s\n' "${hosts[@]}" > "$temp_file"
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
    else
        echo -e "(Auto) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping"
        printf '%s\n' "${hosts[@]}" > "$temp_file"
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
    fi

    if command -v fping >/dev/null 2>&1; then
        if [[ -s "$temp_results" ]]; then
            echo ""
            printf "%-15s %-20s %-25s %-10s %-8s\n" "排名" "网站" "域名" "延迟" "丢包率"
            echo "─────────────────────────────────────────────────────────────────────────"

            local count=1
            declare -a results_array=()

            while IFS= read -r line; do
                if [[ "$line" =~ ([^[:space:]]+)[[:space:]]*:[[:space:]]*(.+) ]]; then
                    local host="${BASH_REMATCH[1]}"
                    local result="${BASH_REMATCH[2]}"

                    local service_name=""
                    for service in "${!FULL_SITES[@]}"; do
                        if [[ "${FULL_SITES[$service]}" == "$host" ]]; then
                            service_name="$service"
                            break
                        fi
                    done
                    [[ -z "$service_name" ]] && service_name="$host"

                    local latency=""
                    local packet_loss="100%"

                    if echo "$result" | grep -q "min/avg/max"; then
                        latency=$(echo "$result" | grep -o 'min/avg/max = [0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'=' -f2 | cut -d'/' -f2 | tr -d ' ')
                        if echo "$result" | grep -q "%loss"; then
                            packet_loss=$(echo "$result" | grep -o '%loss = [^,]*' | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f3)
                        else
                            packet_loss="0%"
                        fi
                        if [[ -n "$latency" ]] && [[ "$latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                            results_array+=("$latency|$service_name|$host|$packet_loss")
                        else
                            results_array+=("999999|$service_name|$host|100%")
                        fi
                    else
                        results_array+=("999999|$service_name|$host|100%")
                    fi
                fi
            done < "$temp_results"

            IFS=$'\n' sorted_results=($(sort -t'|' -k1 -n <<< "${results_array[*]}"))

            for result in "${sorted_results[@]}"; do
                IFS='|' read -r latency service_name host packet_loss <<< "$result"
                if [[ "$latency" == "999999" ]]; then
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${RED}超时/失败 ❌${NC}    ${RED}${packet_loss}${NC}"
                else
                    local latency_int=${latency%.*}
                    local latency_color="${GREEN}"
                    if [[ "$latency_int" -lt 50 ]]; then
                        latency_color="${GREEN}"
                    elif [[ "$latency_int" -lt 150 ]]; then
                        latency_color="${YELLOW}"
                    else
                        latency_color="${RED}"
                    fi
                    local loss_num=$(echo "$packet_loss" | sed 's/%//')
                    local loss_color="${GREEN}"
                    if [[ "$loss_num" == "0" ]]; then
                        loss_color="${GREEN}"
                    elif [[ "$loss_num" -le "5" ]]; then
                        loss_color="${YELLOW}"
                    else
                        loss_color="${RED}"
                    fi
                    local latency_display="$latency"
                    if command -v bc >/dev/null 2>&1; then
                        latency_display=$(printf "%.1f" "$latency" 2>/dev/null || echo "$latency")
                    fi
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${latency_color}${latency_display}ms${NC} ✅    ${loss_color}${packet_loss}${NC}"
                fi
                ((count++))
            done
        else
            echo "❌ fping测试失败或无结果"
        fi
    else
        echo "❌ fping命令不可用，跳过批量测试"
    fi

    rm -f "$temp_file" "$temp_results"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# 解析IPv6地址
get_ipv6_address() {
    local domain=$1
    local ipv6=""
    if command -v dig >/dev/null 2>&1; then
        ipv6=$(dig +short AAAA "$domain" 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -n1)
    fi
    if [[ -z "$ipv6" ]] && command -v nslookup >/dev/null 2>&1; then
        ipv6=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $2}' | grep -E '^[0-9a-f:]+$')
    fi
    echo "$ipv6"
}

# 完整网站列表
declare -A FULL_SITES=(
    ["Google"]="google.com"
    ["GitHub"]="github.com"
    ["Apple"]="apple.com"
    ["Microsoft"]="login.microsoftonline.com"
    ["AWS"]="aws.amazon.com"
    ["Twitter"]="twitter.com"
    ["ChatGPT"]="openai.com"
    ["Steam"]="steampowered.com"
    ["NodeSeek"]="nodeseek.com"
    ["Netflix"]="fast.com"
    ["Disney"]="disneyplus.com"
    ["Instagram"]="instagram.com"
    ["Telegram"]="telegram.org"
    ["OneDrive"]="onedrive.live.com"
    ["Twitch"]="twitch.tv"
    ["Pornhub"]="pornhub.com"
    ["YouTube"]="youtube.com"
    ["Facebook"]="facebook.com"
    ["TikTok"]="tiktok.com"
)

# DNS服务器列表
declare -A DNS_SERVERS=(
    ["系统DNS"]="system"
    ["Google DNS"]="8.8.8.8"
    ["Google备用"]="8.8.4.4"
    ["Cloudflare DNS"]="1.1.1.1"
    ["Cloudflare备用"]="1.0.0.1"
    ["Quad9 DNS"]="9.9.9.9"
    ["Quad9备用"]="149.112.112.112"
    ["OpenDNS"]="208.67.222.222"
    ["OpenDNS备用"]="208.67.220.220"
    ["AdGuard DNS"]="94.140.14.14"
    ["AdGuard备用"]="94.140.15.15"
    ["Comodo DNS"]="8.26.56.26"
    ["Comodo备用"]="8.20.247.20"
    ["Level3 DNS"]="4.2.2.1"
    ["Level3备用"]="4.2.2.2"
    ["Verisign DNS"]="64.6.64.6"
    ["Verisign备用"]="64.6.65.6"
)

# 下载测速端点
declare -A DOWNLOAD_TEST_URLS=(
    ["Cloudflare"]="https://speed.cloudflare.com/__down?bytes=104857600"
    ["CacheFly"]="https://cachefly.cachefly.net/100mb.test"
    ["Hetzner"]="https://speed.hetzner.de/100MB.bin"
)

declare -a RESULTS=()
declare -a DNS_RESULTS=()
declare -a DOWNLOAD_RESULTS=()

# 使用指定 DNS 解析 A 记录
get_ip_address() {
    local domain=$1
    local ip=""
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short @"$SELECTED_DNS_SERVER" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" "$SELECTED_DNS_SERVER" 2>/dev/null | awk '/^Address: /{print $2; exit}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    else
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2; exit}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    fi
    [[ -z "$ip" ]] && ip=$(ping -c 1 "$domain" 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p' | head -n1)
    echo "$ip"
}

# DNS 解析速度测试（多域名）
test_dns_resolution() {
    local domains=("$@")
    local total_params=$#
    local dns_server="${!total_params}"
    local dns_name="${@:$((total_params-1)):1}"
    domains=("${@:1:$((total_params-2))}")

    echo -e "🔍 测试 ${CYAN}${dns_name}${NC} 解析速度..."

    local total_time=0 successful_tests=0 failed_tests=0
    for domain in "${domains[@]}"; do
        echo -n -e "  └─ ${domain}... "
        local start_time end_time resolution_time
        start_time=$(get_timestamp_ms)
        if [[ "$dns_server" = "system" ]]; then
            nslookup "$domain" >/dev/null 2>&1
        else
            nslookup "$domain" "$dns_server" >/dev/null 2>&1
        fi
        end_time=$(get_timestamp_ms)
        resolution_time=$(( end_time - start_time ))

        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}${resolution_time}ms ✅${NC}"
            total_time=$((total_time + resolution_time))
            ((successful_tests++))
        else
            echo -e "${RED}失败 ❌${NC}"
            ((failed_tests++))
        fi
    done

    if (( successful_tests > 0 )); then
        local avg_time=$(( total_time / successful_tests ))
        echo -e "  ${YELLOW}平均: ${avg_time}ms (成功: ${successful_tests}, 失败: ${failed_tests})${NC}"
        local status=""
        if   (( avg_time < 50 ));  then status="优秀"
        elif (( avg_time < 100 )); then status="良好"
        elif (( avg_time < 200 )); then status="一般"
        else                         status="较差"
        fi
        DNS_RESULTS+=("${dns_name}|${dns_server}|${avg_time}|${status}")
    else
        echo -e "  ${RED}全部失败${NC}"
        DNS_RESULTS+=("${dns_name}|${dns_server}|999|失败")
    fi
    echo ""
}

# 下载测速
test_download_speed() {
    local name=$1 url=$2
    echo -n -e "📥 测试 ${CYAN}${name}${NC} 下载速度... "
    local speed_output
    local timeout_cmd=$(get_timeout_cmd)
    if [[ -n "$timeout_cmd" ]]; then
        speed_output=$($timeout_cmd 12 curl -o /dev/null -s -w '%{speed_download}' --max-time 10 --connect-timeout 4 "$url" 2>/dev/null || echo "0")
    else
        speed_output=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 10 --connect-timeout 4 "$url" 2>/dev/null || echo "0")
    fi
    if [[ "$speed_output" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$speed_output > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        local speed_mbps=$(echo "scale=2; $speed_output / 1048576" | bc -l 2>/dev/null)
        if [ "$(echo "$speed_mbps > 0.1" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            echo -e "${GREEN}${speed_mbps} MB/s ⚡${NC}"
            DOWNLOAD_RESULTS+=("${name}|${url}|${speed_mbps} MB/s|成功")
        else
            local speed_kbps=$(echo "scale=0; $speed_output / 1024" | bc -l 2>/dev/null)
            echo -e "${YELLOW}${speed_kbps} KB/s 🐌${NC}"
            DOWNLOAD_RESULTS+=("${name}|${url}|${speed_kbps} KB/s|慢速")
        fi
    else
        echo -e "${RED}失败 ❌${NC}"
        DOWNLOAD_RESULTS+=("${name}|${url}|失败|失败")
    fi
}

# 丢包率（未改动核心逻辑）
test_packet_loss() {
    local host=$1 service=$2
    echo -n -e "📡 测试 ${CYAN}${service}${NC} 丢包率... "
    local ping_result
    local timeout_cmd=$(get_timeout_cmd)
    local ping_cmd=$(get_ping_cmd "4")
    local interval=$(get_ping_interval)
    if [[ -n "$timeout_cmd" ]]; then
        if [[ -n "$interval" ]]; then
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    else
        if [[ -n "$interval" ]]; then
            ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    fi
    if [[ -n "$ping_result" ]]; then
        local packet_loss
        packet_loss=$(echo "$ping_result" | grep "packet loss" | sed -n 's/.*\([0-9]\+\)% packet loss.*/\1/p')
        if [[ -n "$packet_loss" ]]; then
            if   (( packet_loss == 0 )); then echo -e "${GREEN}${packet_loss}% 🟢${NC}"
            elif (( packet_loss < 5 )); then  echo -e "${YELLOW}${packet_loss}% 🟡${NC}"
            else                              echo -e "${RED}${packet_loss}% 🔴${NC}"
            fi
            return "$packet_loss"
        else
            echo -e "${RED}无法检测 ❌${NC}"
            return 100
        fi
    else
        echo -e "${RED}测试失败 ❌${NC}"
        return 100
    fi
}

# 欢迎界面
show_welcome() {
    [[ -t 1 ]] && clear
    echo ""
    echo -e "${CYAN}🚀 ${YELLOW}网络延迟一键检测工具${NC}"
    echo ""
    echo -e "${BLUE}快速检测您的网络连接到各大网站的延迟情况${NC}"
    echo ""
}

# 主菜单
show_menu() {
    echo ""
    echo -e "${CYAN}🎯 选择测试模式${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} 🌐 Ping/真连接测试"
    echo -e "  ${GREEN}2${NC} 🔍 DNS测试"
    echo -e "  ${GREEN}3${NC} 🔄 综合测试"
    echo -e "  ${GREEN}4${NC} 🌍 IPv4/IPv6优先设置"
    echo -e "  ${GREEN}5${NC} ⚙️  DNS解析设置"
    echo -e "  ${RED}0${NC} 🚪 退出程序"
    echo ""
}

# TCP 连接延迟（改为 get_timestamp_ms）
test_tcp_latency() {
    local host=$1 port=$2 count=${3:-3}
    local total_time=0 successful_connects=0
    for ((i=1; i<=count; i++)); do
        local start_time=$(get_timestamp_ms)
        local timeout_cmd=$(get_timeout_cmd)
        if [[ -n "$timeout_cmd" ]]; then
            if $timeout_cmd 5 bash -c "exec 3<>/dev/tcp/$host/$port && exec 3<&- && exec 3>&-" 2>/dev/null; then
                local end_time=$(get_timestamp_ms)
                local connect_time=$(( end_time - start_time ))
                total_time=$(( total_time + connect_time ))
                ((successful_connects++))
            fi
        else
            if bash -c "exec 3<>/dev/tcp/$host/$port && exec 3<&- && exec 3>&-" 2>/dev/null; then
                local end_time=$(get_timestamp_ms)
                local connect_time=$(( end_time - start_time ))
                total_time=$(( total_time + connect_time ))
                ((successful_connects++))
            fi
        fi
    done
    if (( successful_connects > 0 )); then
        echo $(( total_time / successful_connects ))
    else
        echo "999999"
    fi
}

# HTTP 连接延迟
test_http_latency() {
    local host=$1 count=${2:-3}
    local total_time=0 successful_requests=0
    for ((i=1; i<=count; i++)); do
        local timeout_cmd=$(get_timeout_cmd)
        local connect_time
        if [[ -n "$timeout_cmd" ]]; then
            connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        else
            connect_time=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        fi
        if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
            total_time=$(( total_time + time_ms ))
            ((successful_requests++))
        fi
    done
    if (( successful_requests > 0 )); then
        echo $(( total_time / successful_requests ))
    else
        echo "999999"
    fi
}

# 单站延迟（fping 目标改用已解析 IP）
test_site_latency() {
    local host=$1 service=$2 show_ip=${3:-true}

    local test_version="4"
    local version_label="IPv4"
    local target_ip=""
    local ipv6_addr="" ip_addr=""

    if [[ "$IP_VERSION" == "6" ]]; then
        ipv6_addr=$(get_ipv6_address "$host")
        if [[ -n "$ipv6_addr" ]]; then
            test_version="6"; version_label="IPv6"; target_ip="$ipv6_addr"
        else
            test_version="4"; version_label="IPv4(fallback)"; ip_addr=$(get_ip_address "$host"); target_ip="$ip_addr"
        fi
    elif [[ "$IP_VERSION" == "4" ]]; then
        test_version="4"; version_label="IPv4"; ip_addr=$(get_ip_address "$host"); target_ip="$ip_addr"
    else
        test_version="4"; version_label="IPv4"; ip_addr=$(get_ip_address "$host"); target_ip="$ip_addr"
    fi

    echo -n -e "🔍 ${CYAN}$(printf "%-12s" "$service")${NC} "

    local ping_result="" ping_ms="" status="" latency_ms="" packet_loss=0

    # fping 目标：优先用我们解析出的 IP
    local fping_target="$host"
    [[ -n "$target_ip" ]] && fping_target="$target_ip"

    if command -v fping >/dev/null 2>&1; then
        local fping_cmd="" timeout_cmd=$(get_timeout_cmd)
        if [[ "$test_version" == "6" && -n "$ipv6_addr" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            fi
        elif [[ "$test_version" == "4" && -n "$ip_addr" ]]; then
            fping_cmd="fping -4"
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            fi
        else
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 fping -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            else
                ping_result=$(fping -c $PING_COUNT -q "$fping_target" 2>&1 || true)
            fi
        fi

        if [[ -n "$ping_result" ]]; then
            if echo "$ping_result" | grep -q "avg"; then
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*ms' | head -n1 | sed 's/ms//')
            else
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'/' -f2 || echo "")
            fi
            if echo "$ping_result" | grep -q "loss"; then
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% loss' | sed 's/% loss//' || echo "0")
            else
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*%' | sed 's/%//' || echo "0")
            fi
            [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]] && latency_ms="$ping_ms"
        fi
    else
        local ping_cmd=$(get_ping_cmd "$test_version")
        local interval=$(get_ping_interval)
        local timeout_cmd=$(get_timeout_cmd)
        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$fping_target" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$fping_target" 2>/dev/null || true)
            fi
        else
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c $PING_COUNT $interval "$fping_target" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c $PING_COUNT "$fping_target" 2>/dev/null || true)
            fi
        fi

        if [[ -n "$ping_result" ]]; then
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | awk -F'=' '/round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')
            else
                # GNU & BusyBox 通吃
                ping_ms=$(echo "$ping_result" | awk -F'=' '/min\/avg/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')
            fi
            packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% packet loss' | sed 's/% packet loss//' 2>/dev/null || echo "0")
            [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]] && latency_ms="$ping_ms"
        fi
    fi

    # HTTP/TCP 回退
    if [[ -z "$latency_ms" ]]; then
        case "$service" in
            "Telegram")
                local tcp_latency=$(test_tcp_latency "$host" 443 2)
                [[ "$tcp_latency" != "999999" ]] && latency_ms="${tcp_latency}.0"
                ;;
            "Netflix"|"NodeSeek")
                local timeout_cmd=$(get_timeout_cmd) connect_time
                if [[ -n "$timeout_cmd" ]]; then
                    connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                else
                    connect_time=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                fi
                if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0) )); then
                    local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
                    latency_ms="${time_ms}.0"
                fi
                ;;
            *)
                local http_latency=$(test_http_latency "$host" 2)
                [[ "$http_latency" != "999999" ]] && latency_ms="${http_latency}.0"
                ;;
        esac
    fi

    # 输出与记录
    local ip_display="N/A"
    if [[ "$test_version" == "6" && -n "$ipv6_addr" ]]; then
        ip_display="$ipv6_addr"
    elif [[ "$test_version" == "4" && -n "$ip_addr" ]]; then
        ip_display="$ip_addr"
    elif [[ -n "$target_ip" ]]; then
        ip_display="$target_ip"
    fi

    if [[ -n "$latency_ms" && "$latency_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local latency_int=${latency_ms%.*}
        local result_ipv4="N/A" result_ipv6="N/A"
        if [[ "$test_version" == "6" ]]; then
            result_ipv6="${ipv6_addr:-N/A}"
        else
            result_ipv4="${ip_addr:-N/A}"
        fi
        local status_txt=""
        if   (( latency_int < 50 ));  then status_txt="优秀"; echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${GREEN}🟢 优秀${NC}"
        elif (( latency_int < 150 )); then status_txt="良好"; echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${YELLOW}🟡 良好${NC}"
        elif (( latency_int < 500 )); then status_txt="较差"; echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}🔴 较差${NC}"
        else                            status_txt="很差"; echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}💀 很差${NC}"
        fi
        RESULTS+=("$service|$host|${latency_ms}ms|$status_txt|$result_ipv4|$result_ipv6|${packet_loss}%|${version_label}")
    else
        local timeout_cmd=$(get_timeout_cmd) curl_success=false
        if [[ -n "$timeout_cmd" ]]; then
            if $timeout_cmd 5 curl -s --connect-timeout 3 "https://$host" >/dev/null 2>&1; then curl_success=true; fi
        else
            if curl -s --max-time 5 --connect-timeout 3 "https://$host" >/dev/null 2>&1; then curl_success=true; fi
        fi
        if $curl_success; then
            printf "%-8s %-15s %-8s %s连通%s\n" "${version_label}" "${ip_display}" "N/A" "${YELLOW}🟡 " "${NC}"
            local result_ipv4="N/A" result_ipv6="N/A"
            [[ "$test_version" == "6" ]] && result_ipv6="${ipv6_addr:-N/A}" || result_ipv4="${ip_addr:-N/A}"
            RESULTS+=("$service|$host|连通|连通但测不出延迟|$result_ipv4|$result_ipv6|N/A|${version_label}")
        else
            printf "%-8s %-15s %-8s %s失败%s\n" "${version_label}" "N/A" "超时" "${RED}❌ " "${NC}"
            RESULTS+=("$service|$host|超时|失败|N/A|N/A|N/A|${version_label}")
        fi
    fi
}

# 执行完整网站测试
run_test() {
    show_welcome
    echo -e "${CYAN}🌐 开始Ping/真连接测试 (${#FULL_SITES[@]}个网站)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "测试参数: ${YELLOW}${#FULL_SITES[@]}个网站${NC} | Ping次数: ${YELLOW}${PING_COUNT}${NC}"
    if [[ -n "$IP_VERSION" ]]; then echo -e "IP版本: ${YELLOW}IPv${IP_VERSION}优先${NC}"; fi
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        echo -e "DNS解析: ${YELLOW}${SELECTED_DNS_NAME} (${SELECTED_DNS_SERVER})${NC}"
    else
        echo -e "DNS解析: ${YELLOW}系统默认${NC}"
    fi

    show_fping_results
    echo ""
    echo -e "${CYAN}🔗 开始真实连接延迟测试...${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    RESULTS=()
    local start_time=$(date +%s)
    # 固定顺序
    for service in $(printf '%s\n' "${!FULL_SITES[@]}" | sort); do
        host="${FULL_SITES[$service]}"
        test_site_latency "$host" "$service"
    done
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))

    show_results "$total_time"
}

# DNS测试入口（大体保留，修正着色/计时）
run_dns_test() {
    show_welcome
    echo -e "${CYAN}🔍 DNS延迟测试${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}选择测试方式:${NC}"
    echo -e "  ${GREEN}1${NC} - DNS延迟+解析速度综合测试 (推荐)"
    echo -e "  ${GREEN}2${NC} - 传统详细DNS解析测试"
    echo -e "  ${GREEN}3${NC} - DNS综合分析 (测试各DNS解析IP的实际延迟)"
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    echo -n -e "${YELLOW}请选择 (0-3): ${NC}"
    read -r dns_choice

    case $dns_choice in
        1)
            show_welcome
            echo -e "${CYAN}🔍 DNS服务器延迟 + DNS解析速度测试${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            echo ""

            echo -e "${YELLOW}📡 第1步: DNS服务器延迟测试 (使用fping)${NC}"
            echo -e "${BLUE}测试DNS服务器: 17个${NC}"
            echo ""

            local dns_hosts=() dns_host_names=()
            for dns_name in "${!DNS_SERVERS[@]}"; do
                if [[ "${DNS_SERVERS[$dns_name]}" != "system" ]]; then
                    dns_hosts+=("${DNS_SERVERS[$dns_name]}")
                    dns_host_names+=("$dns_name")
                fi
            done

            if command -v fping >/dev/null 2>&1; then
                echo -e "${YELLOW}正在测试DNS服务器网络延迟...${NC}"
                echo ""
                local fping_output
                fping_output=$(fping -c 10 -t 2000 -q "${dns_hosts[@]}" 2>&1)

                declare -a dns_latency_results=()
                for i in "${!dns_host_names[@]}"; do
                    local dns_name="${dns_host_names[$i]}"
                    local ip="${dns_hosts[$i]}"
                    local result=$(echo "$fping_output" | grep "^$ip")
                    if [[ -n "$result" ]]; then
                        local avg=""
                        local loss=""
                        if echo "$result" | grep -q "min/avg/max"; then
                            avg=$(echo "$result" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                            loss=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = [0-9]*\/[0-9]*\/\([0-9]*\)%.*/\1/p')
                        else
                            avg=$(echo "$result" | sed -n 's/.*avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
                            loss=$(echo "$result" | sed -n 's/.*loss = \([0-9]*\)%.*/\1/p')
                        fi
                        if [[ -n "$avg" && -n "$loss" ]]; then
                            local latency_int=${avg%.*} score=0 status=""
                            if   (( loss > 5 ));         then status="差";   score=1000
                            elif (( latency_int < 30 )); then status="优秀"; score=$((latency_int + loss * 10))
                            elif (( latency_int < 60 )); then status="良好"; score=$((latency_int + loss * 10))
                            elif (( latency_int < 120)); then status="一般"; score=$((latency_int + loss * 10))
                            else                           status="较差"; score=$((latency_int + loss * 10))
                            fi
                            dns_latency_results+=("$score|$dns_name|$ip|${avg}ms|${loss}%($status)")
                        else
                            dns_latency_results+=("9999|$dns_name|$ip|解析失败|100%(失败)")
                        fi
                    else
                        dns_latency_results+=("9999|$dns_name|$ip|超时|100%(超时)")
                    fi
                done

                echo ""
                printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "平均延迟" "丢包率"
                echo "─────────────────────────────────────────────────────────────────────────"
                IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_latency_results[@]}" | sort -t'|' -k1 -n))
                local rank=1
                for result in "${sorted_results[@]}"; do
                    IFS='|' read -r score dns_name ip latency status <<< "$result"
                    local status_colored=""
                    if   [[ "$status" == *"优秀"* ]]; then status_colored="${GREEN}✅ 优秀${NC}"
                    elif [[ "$status" == *"良好"* ]]; then status_colored="${YELLOW}✅ 良好${NC}"
                    elif [[ "$status" == *"一般"* ]]; then status_colored="${PURPLE}⚠️ 一般${NC}"
                    elif [[ "$status" == *"较差"* ]]; then status_colored="${RED}❌ 较差${NC}"
                    elif [[ "$status" == *"差"*   ]]; then status_colored="${RED}❌ 差${NC}"
                    else                             status_colored="${RED}❌ 失败${NC}"
                    fi
                    print_aligned_row "$rank" "$dns_name" "$ip" "$latency" "$status_colored"
                    ((rank++))
                done
                echo ""
                echo -e "${GREEN}✅ DNS服务器延迟测试完成${NC}"
                echo ""
                echo -e "${YELLOW}🔍 第2步: DNS解析速度测试 (测试域名: google.com)${NC}"
                echo ""

                declare -a dns_resolution_results=()
                for dns_name in "${!DNS_SERVERS[@]}"; do
                    local dns_server="${DNS_SERVERS[$dns_name]}"
                    local start_time end_time resolution_time
                    start_time=$(get_timestamp_ms)
                    if [[ "$dns_server" == "system" ]]; then
                        nslookup google.com >/dev/null 2>&1
                    else
                        nslookup google.com "$dns_server" >/dev/null 2>&1
                    fi
                    end_time=$(get_timestamp_ms)
                    resolution_time=$(( end_time - start_time ))
                    if [[ $? -eq 0 ]]; then
                        local status=""
                        if   (( resolution_time < 50 ));  then status="优秀"
                        elif (( resolution_time < 100 )); then status="良好"
                        elif (( resolution_time < 200 )); then status="一般"
                        else                                status="较差"
                        fi
                        dns_resolution_results+=("$resolution_time|$dns_name|$dns_server|${resolution_time}ms|$status")
                    else
                        dns_resolution_results+=("9999|$dns_name|$dns_server|解析失败|失败")
                    fi
                done

                echo ""
                echo "📊 DNS解析速度测试结果"
                echo "─────────────────────────────────────────────────────────────────────────"
                printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "解析时间" "状态"
                echo "─────────────────────────────────────────────────────────────────────────"
                IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_resolution_results[@]}" | sort -t'|' -k1 -n))
                local rank=1
                for result in "${sorted_results[@]}"; do
                    IFS='|' read -r _time dns_name server resolution_time status <<< "$result"
                    local status_colored=""
                    case "$status" in
                        优秀) status_colored="${GREEN}优秀${NC}" ;;
                        良好) status_colored="${YELLOW}良好${NC}" ;;
                        一般) status_colored="${PURPLE}一般${NC}" ;;
                        较差) status_colored="${RED}较差${NC}" ;;
                        失败) status_colored="${RED}失败${NC}" ;;
                        *)    status_colored="$status" ;;
                    esac
                    print_aligned_row "$rank" "$dns_name" "$server" "$resolution_time" "$status_colored"
                    ((rank++))
                done
                echo ""
                echo -e "${GREEN}✅ DNS解析速度测试完成${NC}"
            else
                echo -e "${RED}fping未安装，无法进行批量测试${NC}"
                echo -e "${YELLOW}请安装fping: brew install fping / apt install fping${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}🔍 开始全球DNS解析速度测试（测试所有网站）${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "测试网站: ${YELLOW}${#FULL_SITES[@]}个网站${NC} | DNS服务器: ${YELLOW}$(echo ${!DNS_SERVERS[@]} | wc -w | tr -d ' ')个${NC}"
            echo ""
            DNS_RESULTS=()
            local start_time=$(date +%s)
            local all_domains=()
            for domain in "${FULL_SITES[@]}"; do all_domains+=("$domain"); done
            for dns_name in "${!DNS_SERVERS[@]}"; do
                dns_server="${DNS_SERVERS[$dns_name]}"
                test_dns_resolution "${all_domains[@]}" "$dns_name" "$dns_server"
            done
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            show_dns_results "$total_time"
            ;;
        3)
            run_dns_comprehensive_analysis
            ;;
        0) return ;;
        *) echo -e "${RED}❌ 无效选择${NC}"; sleep 1; run_dns_test ;;
    esac
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键继续...${NC}"; read -r
    fi
}

# IPv4/IPv6优先设置
run_ip_version_test() {
    show_welcome
    echo -e "${CYAN}🌍 IPv4/IPv6优先设置${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明: 仅影响测试，不会更改系统配置${NC}"
    echo ""
    echo -e "${YELLOW}选择测试协议优先级:${NC}"
    echo -e "  ${GREEN}1${NC} - IPv4优先测试"
    echo -e "  ${GREEN}2${NC} - IPv6优先测试"
    echo -e "  ${GREEN}3${NC} - 自动选择 (系统默认)"
    echo -e "  ${GREEN}4${NC} - 查看当前设置"
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    case $IP_VERSION in
        "4") echo -e "${CYAN}当前设置: IPv4优先${NC}" ;;
        "6") echo -e "${CYAN}当前设置: IPv6优先${NC}" ;;
        "")  echo -e "${CYAN}当前设置: 自动选择${NC}" ;;
    esac
    echo ""
    echo -n -e "${YELLOW}请选择 (0-5): ${NC}"
    read -r ip_choice
    case $ip_choice in
        1) IP_VERSION="4"; echo -e "${GREEN}✅ 已设置为IPv4优先模式${NC}"; sleep 1; run_ip_version_test ;;
        2) IP_VERSION="6"; echo -e "${GREEN}✅ 已设置为IPv6优先模式${NC}"; sleep 1; run_ip_version_test ;;
        3) IP_VERSION="";  echo -e "${GREEN}✅ 已设置为自动选择模式${NC}"; sleep 1; run_ip_version_test ;;
        4)
            echo ""
            echo -e "${CYAN}📋 当前IP协议设置详情:${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            case $IP_VERSION in
                "4") echo -e "优先级: ${GREEN}IPv4优先${NC}\n说明: 测试时优先尝试IPv4地址连接" ;;
                "6") echo -e "优先级: ${GREEN}IPv6优先${NC}\n说明: 测试时优先尝试IPv6地址连接" ;;
                "")  echo -e "优先级: ${GREEN}自动选择${NC}\n说明: 使用系统默认IP协议栈" ;;
            esac
            echo ""
            echo -n -e "${YELLOW}按 Enter 键继续...${NC}"; read -r; run_ip_version_test ;;
        0) return ;;
        *) echo -e "${RED}❌ 无效选择${NC}"; sleep 1; run_ip_version_test ;;
    esac
}

# 综合测试
run_comprehensive_test() {
    show_welcome
    echo -e "${CYAN}📊 开始综合测试 (Ping/真连接+下载速度)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        echo -e "🔍 DNS解析设置: ${YELLOW}${SELECTED_DNS_NAME} (${SELECTED_DNS_SERVER})${NC}"
    else
        echo -e "🔍 DNS解析设置: ${YELLOW}系统默认${NC}"
    fi
    echo ""

    RESULTS=()
    DOWNLOAD_RESULTS=()
    local start_time=$(date +%s 2>/dev/null || echo 0)

    show_fping_results
    echo ""
    echo -e "${YELLOW}📡 第1步: 真实连接延迟测试${NC}"
    echo ""
    for service in $(printf '%s\n' "${!FULL_SITES[@]}" | sort); do
        host="${FULL_SITES[$service]}"
        test_site_latency "$host" "$service"
    done

    echo ""
    echo -e "${YELLOW}🔍 第2步: DNS延迟+解析速度综合测试${NC}"
    echo ""
    echo -e "${YELLOW}📡 DNS服务器延迟测试 (使用fping)${NC}"
    echo -e "${BLUE}测试DNS服务器: 17个${NC}"
    echo ""

    local dns_hosts=() dns_host_names=()
    for dns_name in "${!DNS_SERVERS[@]}"; do
        if [[ "${DNS_SERVERS[$dns_name]}" != "system" ]]; then
            dns_hosts+=("${DNS_SERVERS[$dns_name]}"); dns_host_names+=("$dns_name")
        fi
    done

    if command -v fping >/dev/null 2>&1; then
        echo -e "${YELLOW}正在测试DNS服务器网络延迟...${NC}"
        echo ""
        local fping_output
        fping_output=$(fping -c 10 -t 2000 -q "${dns_hosts[@]}" 2>&1)
        declare -a dns_latency_results=()
        for i in "${!dns_host_names[@]}"; do
            local dns_name="${dns_host_names[$i]}" ip="${dns_hosts[$i]}"
            local result=$(echo "$fping_output" | grep "^$ip")
            if [[ -n "$result" ]]; then
                local avg="" loss=""
                if echo "$result" | grep -q "min/avg/max"; then
                    avg=$(echo "$result" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                    loss=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = [0-9]*\/[0-9]*\/\([0-9]*\)%.*/\1/p')
                else
                    avg=$(echo "$result" | sed -n 's/.*avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
                    loss=$(echo "$result" | sed -n 's/.*loss = \([0-9]*\)%.*/\1/p')
                fi
                if [[ -n "$avg" && -n "$loss" ]]; then
                    local latency_int=${avg%.*} score=0 status=""
                    if   (( loss > 5 ));         then status="差";   score=1000
                    elif (( latency_int < 30 )); then status="优秀"; score=$((latency_int + loss * 10))
                    elif (( latency_int < 60 )); then status="良好"; score=$((latency_int + loss * 10))
                    elif (( latency_int < 120)); then status="一般"; score=$((latency_int + loss * 10))
                    else                           status="较差"; score=$((latency_int + loss * 10))
                    fi
                    dns_latency_results+=("$score|$dns_name|$ip|${avg}ms|${loss}%($status)")
                else
                    dns_latency_results+=("9999|$dns_name|$ip|解析失败|100%(失败)")
                fi
            else
                dns_latency_results+=("9999|$dns_name|$ip|超时|100%(超时)")
            fi
        done

        echo ""
        printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "平均延迟" "丢包率"
        echo "─────────────────────────────────────────────────────────────────────────"
        IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_latency_results[@]}" | sort -t'|' -k1 -n))
        local rank=1
        for result in "${sorted_results[@]}"; do
            IFS='|' read -r score dns_name ip latency status <<< "$result"
            local status_colored=""
            if   [[ "$status" == *"优秀"* ]]; then status_colored="${GREEN}✅ 优秀${NC}"
            elif [[ "$status" == *"良好"* ]]; then status_colored="${YELLOW}✅ 良好${NC}"
            elif [[ "$status" == *"一般"* ]]; then status_colored="${PURPLE}⚠️ 一般${NC}"
            elif [[ "$status" == *"较差"* ]]; then status_colored="${RED}❌ 较差${NC}"
            elif [[ "$status" == *"差"*   ]]; then status_colored="${RED}❌ 差${NC}"
            else                             status_colored="${RED}❌ 失败${NC}"
            fi
            print_aligned_row "$rank" "$dns_name" "$ip" "$latency" "$status_colored"
            ((rank++))
        done
        echo ""
        echo -e "${GREEN}✅ DNS服务器延迟测试完成${NC}"
        echo ""
    fi

    echo -e "${YELLOW}🔍 DNS解析速度测试 (测试域名: google.com)${NC}"
    echo ""
    local all_domains=("google.com")
    DNS_RESULTS=()
    for dns_name in "${!DNS_SERVERS[@]}"; do
        dns_server="${DNS_SERVERS[$dns_name]}"
        test_dns_resolution "${all_domains[@]}" "$dns_name" "$dns_server"
    done

    if [[ ${#DNS_RESULTS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}📊 DNS解析速度测试结果${NC}"
        echo "─────────────────────────────────────────────────────────────────────────"
        printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "解析时间" "状态"
        echo "─────────────────────────────────────────────────────────────────────────"
        IFS=$'\n' sorted_dns=($(printf '%s\n' "${DNS_RESULTS[@]}" | sort -t'|' -k3 -n))
        local rank=1
        for result in "${sorted_dns[@]}"; do
            IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
            local display_server="$dns_server"
            [[ "$dns_server" == "system" ]] && display_server="系统默认"
            local status_colored=""
            case "$status" in
                优秀) status_colored="${GREEN}优秀${NC}" ;;
                良好) status_colored="${YELLOW}良好${NC}" ;;
                一般) status_colored="${PURPLE}一般${NC}" ;;
                较差) status_colored="${RED}较差${NC}" ;;
                失败) status_colored="${RED}失败${NC}" ;;
                *)    status_colored="$status" ;;
            esac
            print_aligned_row "$rank" "$dns_name" "$display_server" "${resolution_time}ms" "$status_colored"
            ((rank++))
        done
        echo ""
        echo -e "${GREEN}✅ DNS解析速度测试完成${NC}"
        echo ""
    fi

    echo ""
    echo -e "${YELLOW}📥 第3步: 下载速度测试${NC}"
    echo ""
    for test_name in "${!DOWNLOAD_TEST_URLS[@]}"; do
        test_url="${DOWNLOAD_TEST_URLS[$test_name]}"
        test_download_speed "$test_name" "$test_url"
    done

    local end_time=$(date +%s 2>/dev/null || echo 0)
    local total_time=$((end_time - start_time))
    (( total_time < 0 || total_time > 10000 )) && total_time=0

    show_comprehensive_results "$total_time"
}

# 展示延迟测试结果（修正排序与分组）
show_results() {
    local total_time=$1
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    echo -e "${CYAN}📋 延迟测试结果表格:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "%-3s %-12s %-25s %-12s %-8s %-15s %-15s %-8s\n" "排名" "服务" "域名" "延迟" "状态" "IPv4地址" "IPv6地址" "版本"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────────────────────────────────${NC}"

    declare -a ok_results=() failed_results=()
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r _svc _host latency _status _v4 _v6 _pl _ver <<< "$result"
        if [[ "$latency" =~ ^[0-9.]+ms$ ]]; then
            ok_results+=("$result")
        else
            failed_results+=("$result")
        fi
    done

    IFS=$'\n' ok_results=($(printf '%s\n' "${ok_results[@]}" | sort -t'|' -k3,3g))

    local rank=1
    for result in "${ok_results[@]}"; do
        IFS='|' read -r service host latency status ipv4_addr ipv6_addr packet_loss version <<< "$result"
        local status_colored=""
        case "$status" in
            "优秀") status_colored="${GREEN}🟢 $status${NC}" ;;
            "良好") status_colored="${YELLOW}🟡 $status${NC}" ;;
            "较差") status_colored="${RED}🔴 $status${NC}" ;;
            "很差") status_colored="${RED}💀 $status${NC}" ;;
            *)      status_colored="$status" ;;
        esac
        local ipv4_display="$ipv4_addr" ipv6_display="$ipv6_addr"
        [[ ${#ipv4_addr} -gt 15 ]] && ipv4_display="${ipv4_addr:0:12}..."
        [[ ${#ipv6_addr} -gt 15 ]] && ipv6_display="${ipv6_addr:0:12}..."
        echo -e "$(printf "%2d. %-10s %-25s %-12s %-15s %-15s %-15s %s" "$rank" "$service" "$host" "$latency" "$status_colored" "$ipv4_display" "$ipv6_display" "${version:-IPv4}")"
        ((rank++))
    done

    for result in "${failed_results[@]}"; do
        IFS='|' read -r service host latency status ipv4_addr ipv6_addr packet_loss version <<< "$result"
        echo -e "$(printf "%2d. %-10s %-25s %-12s" "$rank" "$service" "$host" "$latency") ${RED}❌ $status${NC} $(printf "%-15s %-15s %-8s %s" "${ipv4_addr:-N/A}" "${ipv6_addr:-N/A}" "${packet_loss:-N/A}" "${version:-IPv4}")"
        ((rank++))
    done

    local excellent_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "优秀" || true)
    local good_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "良好" || true)
    local poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "较差" || true)
    local very_poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "很差" || true)
    local failed_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "失败" || true)

    echo ""
    echo -e "${CYAN}📈 统计摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    echo -e "🟢 优秀 (< 50ms):     ${GREEN}$excellent_count${NC} 个服务"
    echo -e "🟡 良好 (50-150ms):   ${YELLOW}$good_count${NC} 个服务"
    echo -e "🔴 较差 (150-500ms):  ${RED}$poor_count${NC} 个服务"
    echo -e "💀 很差 (> 500ms):    ${RED}$very_poor_count${NC} 个服务"
    echo -e "❌ 失败:             ${RED}$failed_count${NC} 个服务"

    local total_tested=$((excellent_count + good_count + poor_count + very_poor_count + failed_count))
    if (( total_tested > 0 )); then
        local success_rate=$(((excellent_count + good_count + poor_count + very_poor_count) * 100 / total_tested))
        echo ""
        if   (( success_rate > 80 && excellent_count > good_count )); then
            echo -e "🌟 ${GREEN}网络状况: 优秀${NC} (成功率: ${success_rate}%)"
        elif (( success_rate > 60 )); then
            echo -e "👍 ${YELLOW}网络状况: 良好${NC} (成功率: ${success_rate}%)"
        else
            echo -e "⚠️  ${RED}网络状况: 一般${NC} (成功率: ${success_rate}%)"
        fi
    fi

    local output_file="latency_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# 网络延迟测试结果 - $(date)"
        echo "# 服务|域名|延迟|状态|IPv4地址|IPv6地址|丢包率"
        printf '%s\n' "${RESULTS[@]}"
    } > "$output_file"

    echo ""
    echo -e "💾 结果已保存到: ${GREEN}$output_file${NC}"
    echo ""
    echo -e "${CYAN}💡 延迟等级说明:${NC}"
    echo -e "  ${GREEN}🟢 优秀${NC} (< 50ms)     - 适合游戏、视频通话"
    echo -e "  ${YELLOW}🟡 良好${NC} (50-150ms)   - 适合网页浏览、视频"
    echo -e "  ${RED}🔴 较差${NC} (150-500ms)  - 基础使用，可能影响体验"
    echo -e "  ${RED}💀 很差${NC} (> 500ms)    - 网络质量很差"

    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"; read -r
    else
        echo -e "${YELLOW}测试完成！${NC}"
        exit 0
    fi
}

# 显示 DNS 测试结果（修正着色）
show_dns_results() {
    local total_time=$1
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🔍 DNS测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    echo -e "${CYAN}📋 DNS解析速度结果:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    printf "%-3s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务商" "DNS服务器" "解析时间" "状态"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"

    declare -a sorted_dns_results=() failed_dns_results=()
    for result in "${DNS_RESULTS[@]}"; do
        if [[ "$result" == *"失败"* ]]; then
            failed_dns_results+=("$result")
        else
            sorted_dns_results+=("$result")
        fi
    done

    IFS=$'\n' sorted_dns_results=($(printf '%s\n' "${sorted_dns_results[@]}" | sort -t'|' -k3 -n))

    local rank=1
    for result in "${sorted_dns_results[@]}"; do
        IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
        local status_colored=""
        case "$status" in
            优秀) status_colored="${GREEN}✅ $status${NC}" ;;
            良好) status_colored="${YELLOW}✅ $status${NC}" ;;
            一般) status_colored="${PURPLE}⚠️ $status${NC}" ;;
            较差) status_colored="${RED}❌ $status${NC}" ;;
            失败) status_colored="${RED}❌ $status${NC}" ;;
            *)    status_colored="$status" ;;
        esac
        echo -e "$(printf "%2d. %-13s %-20s %-12s" "$rank" "$dns_name" "$dns_server" "${resolution_time}ms") $status_colored"
        ((rank++))
    done

    for result in "${failed_dns_results[@]}"; do
        IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
        echo -e "$(printf "%2d. %-13s %-20s %-12s" "$rank" "$dns_name" "$dns_server" "${resolution_time}ms") ${RED}❌ $status${NC}"
        ((rank++))
    done

    echo ""
    echo -e "${CYAN}💡 DNS优化建议:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    # 简要建议
    echo -e "📊 常见选择：Google(8.8.8.8) 稳定 | Cloudflare(1.1.1.1) 快且注重隐私 | Quad9(9.9.9.9) 安全过滤"

    local dns_output_file="dns_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# DNS解析速度测试结果 - $(date)"
        echo "# DNS服务商|DNS服务器|解析时间|状态"
        printf '%s\n' "${DNS_RESULTS[@]}"
    } > "$dns_output_file"

    echo ""
    echo -e "💾 DNS测试结果已保存到: ${GREEN}$dns_output_file${NC}"
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"; read -r
    else
        echo -e "${YELLOW}DNS测试完成！${NC}"
        exit 0
    fi
}

# 综合结果摘要
show_comprehensive_results() {
    local total_time=$1
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 综合测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    echo -e "${CYAN}🚀 网站延迟测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    local excellent_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "优秀" || true)
    local good_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "良好" || true)
    local poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "较差" || true)
    echo -e "🟢 优秀: ${excellent_count}个  🟡 良好: ${good_count}个  🔴 较差: ${poor_count}个"

    echo ""
    echo -e "${CYAN}🔍 DNS解析测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if (( ${#DNS_RESULTS[@]} > 0 )); then
        local fastest_dns="" fastest_time=9999
        for result in "${DNS_RESULTS[@]}"; do
            if [[ "$result" != *"失败"* ]]; then
                IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
                local t="${resolution_time}"
                if [[ "$t" =~ ms$ ]]; then t="${t%ms}"; fi
                if (( t < fastest_time )); then fastest_time="$t"; fastest_dns="$dns_name"; fi
            fi
        done
        [[ -n "$fastest_dns" ]] && echo -e "🏆 最快DNS: ${GREEN}${fastest_dns}${NC} (${fastest_time}ms)"
    fi

    echo ""
    echo -e "${CYAN}📥 下载速度测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if (( ${#DOWNLOAD_RESULTS[@]} > 0 )); then
        for result in "${DOWNLOAD_RESULTS[@]}"; do
            IFS='|' read -r test_name test_url speed status <<< "$result"
            case "$status" in
                "成功") echo -e "✅ ${test_name}: ${GREEN}${speed}${NC}" ;;
                "慢速") echo -e "🐌 ${test_name}: ${YELLOW}${speed}${NC}" ;;
                "失败") echo -e "❌ ${test_name}: ${RED}测试失败${NC}" ;;
            esac
        done
    fi

    local comprehensive_output_file="comprehensive_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# 综合网络测试结果 - $(date)"
        echo ""
        echo "## 网站延迟测试结果"
        echo "# 服务|域名|延迟|状态|IPv4地址|IPv6地址|丢包率"
        printf '%s\n' "${RESULTS[@]}"
        echo ""
        echo "## DNS解析速度测试结果"
        echo "# DNS服务商|DNS服务器|解析时间|状态"
        printf '%s\n' "${DNS_RESULTS[@]}"
        echo ""
        echo "## 下载速度测试结果"
        echo "# 测试点|URL|速度|状态"
        printf '%s\n' "${DOWNLOAD_RESULTS[@]}"
    } > "$comprehensive_output_file"

    echo ""
    echo -e "💾 综合测试结果已保存到: ${GREEN}$comprehensive_output_file${NC}"
    echo ""
    echo -e "${CYAN}💡 网络优化建议:${NC}"
    echo -e "  1. 延迟优化: 选择延迟最低的服务器"
    echo -e "  2. DNS优化: 使用解析最快的DNS服务器"
    echo -e "  3. 下载优化: 选择下载速度最快的CDN节点"

    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"; read -r
    else
        echo -e "${YELLOW}综合测试完成！${NC}"
        exit 0
    fi
}

# 依赖检查（加入 dig）
check_dependencies() {
    echo -e "${CYAN}🔧 检查系统依赖...${NC}"
    echo -e "系统类型: ${YELLOW}$OS_TYPE${NC} | Bash版本: ${YELLOW}${BASH_VERSION%%.*}${NC}"

    local missing_deps=() install_cmd=""
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        install_cmd="yum"
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd="dnf"
    elif command -v apk >/dev/null 2>&1; then
        install_cmd="apk"
    elif command -v brew >/dev/null 2>&1; then
        install_cmd="brew"
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd="pacman"
    fi

    command -v ping >/dev/null 2>&1 || missing_deps+=("ping")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v bc   >/dev/null 2>&1 || missing_deps+=("bc")
    command -v nslookup >/dev/null 2>&1 || missing_deps+=("nslookup")
    command -v dig >/dev/null 2>&1 || missing_deps+=("dig")

    if ! command -v timeout >/dev/null 2>&1 && [[ "$OS_TYPE" == "macos" ]]; then
        echo -e "${YELLOW}💡 macOS建议安装coreutils以获得timeout命令: brew install coreutils${NC}"
    fi
    if ! command -v fping >/dev/null 2>&1; then
        echo -e "${YELLOW}💡 建议安装 fping 以获得更好的性能${NC}"
        missing_deps+=("fping")
    fi

    if (( ${#missing_deps[@]} )); then
        echo -e "${YELLOW}⚠️  缺失依赖: ${missing_deps[*]}${NC}"
        if [[ -n "$install_cmd" && "$(id -u)" = "0" ]]; then
            echo -e "${CYAN}🚀 正在自动安装依赖...${NC}"
            case $install_cmd in
                "apt-get")
                    apt-get update -qq >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "ping"      && apt-get install -y iputils-ping >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "curl"      && apt-get install -y curl >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "bc"        && apt-get install -y bc >/dev/null 2>&1
                    # dnsutils 提供 nslookup 和 dig
                    if echo "${missing_deps[*]}" | grep -Eq "nslookup|dig"; then
                        apt-get install -y dnsutils >/dev/null 2>&1
                    fi
                    echo "${missing_deps[*]}" | grep -q "fping"     && apt-get install -y fping >/dev/null 2>&1
                    ;;
                "yum"|"dnf")
                    echo "${missing_deps[*]}" | grep -q "ping"      && $install_cmd install -y iputils >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "curl"      && $install_cmd install -y curl >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "bc"        && $install_cmd install -y bc >/dev/null 2>&1
                    # bind-utils 提供 nslookup 和 dig
                    if echo "${missing_deps[*]}" | grep -Eq "nslookup|dig"; then
                        $install_cmd install -y bind-utils >/dev/null 2>&1
                    fi
                    echo "${missing_deps[*]}" | grep -q "fping"     && $install_cmd install -y fping >/dev/null 2>&1
                    ;;
                "apk")
                    apk update >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "ping"      && apk add iputils >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "curl"      && apk add curl >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "bc"        && apk add bc >/dev/null 2>&1
                    # bind-tools 提供 nslookup 和 dig
                    if echo "${missing_deps[*]}" | grep -Eq "nslookup|dig"; then
                        apk add bind-tools >/dev/null 2>&1
                    fi
                    echo "${missing_deps[*]}" | grep -q "fping"     && apk add fping >/dev/null 2>&1
                    ;;
                "brew")
                    echo "${missing_deps[*]}" | grep -q "curl"      && brew install curl >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "bc"        && brew install bc >/dev/null 2>&1
                    # macOS 自带 nslookup；dig 在 bind 工具里
                    echo "${missing_deps[*]}" | grep -q "dig"       && brew install bind >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "fping"     && brew install fping >/dev/null 2>&1
                    ;;
                "pacman")
                    echo "${missing_deps[*]}" | grep -q "ping"      && pacman -S --noconfirm iputils >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "curl"      && pacman -S --noconfirm curl >/dev/null 2>&1
                    echo "${missing_deps[*]}" | grep -q "bc"        && pacman -S --noconfirm bc >/dev/null 2>&1
                    # Arch 提供 dig 的包为 bind
                    if echo "${missing_deps[*]}" | grep -Eq "nslookup|dig"; then
                        pacman -S --noconfirm bind >/dev/null 2>&1
                    fi
                    echo "${missing_deps[*]}" | grep -q "fping"     && pacman -S --noconfirm fping >/dev/null 2>&1
                    ;;
            esac

            local still_missing=()
            for dep in "${missing_deps[@]}"; do
                case $dep in
                    "ping")      command -v ping      >/dev/null 2>&1 || still_missing+=("ping") ;;
                    "curl")      command -v curl      >/dev/null 2>&1 || still_missing+=("curl") ;;
                    "bc")        command -v bc        >/dev/null 2>&1 || still_missing+=("bc") ;;
                    "nslookup")  command -v nslookup  >/dev/null 2>&1 || still_missing+=("nslookup") ;;
                    "dig")       command -v dig       >/dev/null 2>&1 || still_missing+=("dig") ;;
                    "fping")     command -v fping     >/dev/null 2>&1 || still_missing+=("fping") ;;
                esac
            done

            if (( ${#still_missing[@]} == 0 )); then
                echo -e "${GREEN}✅ 所有依赖安装成功！${NC}"
            else
                echo -e "${RED}❌ 部分依赖安装失败: ${still_missing[*]}${NC}"
                show_manual_install_instructions
                exit 1
            fi
        else
            echo -e "${RED}❌ 无法自动安装依赖${NC}"
            [[ "$(id -u)" != "0" ]] && echo -e "${YELLOW}💡 提示: 请使用 root 权限运行脚本以自动安装依赖${NC}"
            show_manual_install_instructions
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 所有依赖已安装${NC}"
    fi
    echo ""
}

# 手动安装说明
show_manual_install_instructions() {
    echo ""
    echo -e "${CYAN}📝 手动安装说明:${NC}"
    echo ""
    echo "🐧 Ubuntu/Debian:"
    echo "   sudo apt update && sudo apt install curl iputils-ping bc dnsutils fping"
    echo ""
    echo "🎩 CentOS/RHEL/Fedora:"
    echo "   sudo yum install curl iputils bc bind-utils fping"
    echo "   # 或者: sudo dnf install curl iputils bc bind-utils fping"
    echo ""
    echo "🏔️  Alpine Linux:"
    echo "   sudo apk update && sudo apk add curl iputils bc bind-tools fping"
    echo ""
    echo "🍎 macOS:"
    echo "   brew install curl bc bind fping"
    echo "   # ping 和 nslookup 通常已预装，timeout 在 coreutils 中（gtimeout）"
    echo ""
}

# DNS 设置管理
run_dns_management() {
    show_welcome
    echo -e "${CYAN}⚙️ DNS设置管理${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明: 仅影响脚本解析，不修改系统 DNS${NC}"
    echo ""
    echo -e "${YELLOW}选择用于IP解析的DNS服务器:${NC}"

    local count=1
    declare -a dns_list=()
    echo -e "  ${GREEN}$count${NC} - 系统默认 (使用系统DNS设置)"
    dns_list+=("system|系统默认"); ((count++))
    for dns_name in "${!DNS_SERVERS[@]}"; do
        local dns_server="${DNS_SERVERS[$dns_name]}"
        if [[ "$dns_server" != "system" ]]; then
            echo -e "  ${GREEN}$count${NC} - $dns_name ($dns_server)"
            dns_list+=("$dns_server|$dns_name"); ((count++))
        fi
    done
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    if [[ -z "$SELECTED_DNS_SERVER" || "$SELECTED_DNS_SERVER" == "system" ]]; then
        echo -e "${CYAN}当前设置: 系统默认${NC}"
    else
        echo -e "${CYAN}当前设置: $SELECTED_DNS_NAME ($SELECTED_DNS_SERVER)${NC}"
    fi
    echo ""
    echo -n -e "${YELLOW}请选择 (0-$((count-1))): ${NC}"
    read -r dns_choice

    case $dns_choice in
        0) return ;;
        1)
            SELECTED_DNS_SERVER="system"; SELECTED_DNS_NAME="系统默认"
            echo -e "${GREEN}✅ 已设置为系统默认DNS${NC}"
            sleep 1
            ;;
        *)
            if [[ "$dns_choice" =~ ^[0-9]+$ ]] && (( dns_choice >= 2 && dns_choice <= count-1 )); then
                local selected_dns="${dns_list[$((dns_choice-1))]}"
                SELECTED_DNS_SERVER=$(echo "$selected_dns" | cut -d'|' -f1)
                SELECTED_DNS_NAME=$(echo "$selected_dns" | cut -d'|' -f2)
                echo -e "${GREEN}✅ 已设置DNS服务器为: $SELECTED_DNS_NAME ($SELECTED_DNS_SERVER)${NC}"
                sleep 1
            else
                echo -e "${RED}❌ 无效选择${NC}"
                sleep 1
                run_dns_management
                return
            fi
            ;;
    esac

    echo ""
    echo -e "${YELLOW}是否立即进行网站连接测试？${NC}"
    echo -e "  ${GREEN}1${NC} - 是，进行Ping/真连接测试"
    echo -e "  ${GREEN}2${NC} - 是，进行综合测试"
    echo -e "  ${RED}0${NC} - 否，返回主菜单"
    echo ""
    echo -n -e "${YELLOW}请选择 (0-2): ${NC}"
    read -r test_choice
    case $test_choice in
        1) run_test ;;
        2) run_comprehensive_test ;;
        0|*) return ;;
    esac
}

# 用指定 DNS 解析域名并返回 IP
resolve_with_dns() {
    local domain=$1 dns_server=$2 ip=""
    if [[ "$dns_server" == "system" ]]; then
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2; exit}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    else
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short @"$dns_server" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" "$dns_server" 2>/dev/null | awk '/^Address: /{print $2; exit}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    fi
    echo "$ip"
}

# 测试 IP ping 延迟（1 次多轮求均值）
test_ip_latency() {
    local ip=$1 count=${2:-5}
    if [[ -z "$ip" || "$ip" == "N/A" ]]; then echo "999999"; return; fi
    local total_time=0 successful_pings=0
    local ping_cmd=$(get_ping_cmd "4")
    local interval=$(get_ping_interval)
    local timeout_cmd=$(get_timeout_cmd)
    for ((i=1; i<=count; i++)); do
        local ping_result=""
        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 5 $ping_cmd -c 1 $interval "$ip" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 5 $ping_cmd -c 1 "$ip" 2>/dev/null || true)
            fi
        else
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c 1 $interval "$ip" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c 1 "$ip" 2>/dev/null || true)
            fi
        fi
        if [[ -n "$ping_result" ]]; then
            local ping_ms=""
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | awk -F'time=' '{print $2}' | awk '{print $1}')
                [[ -z "$ping_ms" ]] && ping_ms=$(echo "$ping_result" | awk -F'=' '/round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')
            else
                ping_ms=$(echo "$ping_result" | awk -F'time=' '{print $2}' | awk '{print $1}')
                [[ -z "$ping_ms" ]] && ping_ms=$(echo "$ping_result" | awk -F'=' '/min\/avg/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')
            fi
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                total_time=$(echo "$total_time + $ping_ms" | bc -l 2>/dev/null || echo "$total_time")
                ((successful_pings++))
            fi
        fi
    done
    if (( successful_pings > 0 )); then
        echo "scale=1; $total_time / $successful_pings" | bc -l 2>/dev/null || echo "999999"
    else
        echo "999999"
    fi
}

# DNS 综合分析（用 get_timestamp_ms）
run_dns_comprehensive_analysis() {
    show_welcome
    echo -e "${CYAN}🧪 DNS综合分析 - 测试各DNS解析IP的实际延迟${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}📋 测试说明：${NC}"
    echo -e "   • 使用每个DNS服务器解析测试域名获得IP地址"
    echo -e "   • 测试解析出的IP地址的实际ping延迟"
    echo -e "   • 综合考虑DNS解析速度和ping延迟给出最佳建议"
    echo ""
    local test_domains=("google.com" "github.com" "apple.com")
    echo -e "${CYAN}🎯 测试域名: ${test_domains[*]}${NC}"
    echo ""
    declare -a analysis_results=()
    local dns_count=0 total_dns=${#DNS_SERVERS[@]}
    for dns_name in "${!DNS_SERVERS[@]}"; do
        local dns_server="${DNS_SERVERS[$dns_name]}"; ((dns_count++))
        echo -e "${BLUE}[$dns_count/$total_dns]${NC} 测试 ${CYAN}$dns_name${NC} (${dns_server})..."
        local total_resolution_time=0 total_ping_time=0 successful_resolutions=0 successful_pings=0
        for domain in "${test_domains[@]}"; do
            echo -n "  └─ $domain: "
            local start_time=$(get_timestamp_ms)
            local resolved_ip
            resolved_ip=$(resolve_with_dns "$domain" "$dns_server")
            local end_time=$(get_timestamp_ms)
            local resolution_time=$(( end_time - start_time ))
            if [[ -n "$resolved_ip" && "$resolved_ip" != "N/A" ]]; then
                total_resolution_time=$(( total_resolution_time + resolution_time ))
                ((successful_resolutions++))
                echo -n "${resolved_ip} (解析${resolution_time}ms) "
                local ping_latency
                ping_latency=$(test_ip_latency "$resolved_ip" 3)
                if [[ "$ping_latency" != "999999" && "$ping_latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    total_ping_time=$(echo "$total_ping_time + $ping_latency" | bc -l 2>/dev/null || echo "$total_ping_time")
                    ((successful_pings++))
                    echo -e "${GREEN}ping${ping_latency}ms ✅${NC}"
                else
                    echo -e "${RED}ping失败 ❌${NC}"
                fi
            else
                echo -e "${RED}解析失败 ❌${NC}"
            fi
        done
        local avg_resolution_time=9999 avg_ping_time=9999
        (( successful_resolutions > 0 )) && avg_resolution_time=$(( total_resolution_time / successful_resolutions ))
        if (( successful_pings > 0 )); then
            avg_ping_time=$(echo "scale=1; $total_ping_time / $successful_pings" | bc -l 2>/dev/null || echo "9999")
        fi

        # 综合评分
        local composite_score=0
        if [[ "$avg_ping_time" != "9999" && "$avg_resolution_time" != "9999" ]]; then
            local ping_time_int=${avg_ping_time%.*}
            local resolution_time_int=${avg_resolution_time%.*}
            [[ ! "$ping_time_int" =~ ^[0-9]+$ ]] && ping_time_int=999
            [[ ! "$resolution_time_int" =~ ^[0-9]+$ ]] && resolution_time_int=999
            local ping_score=0 dns_score=0
            if   (( ping_time_int <= 20 ));  then ping_score=70
            elif (( ping_time_int <= 40 ));  then ping_score=$((70 - (ping_time_int - 20) / 2))
            elif (( ping_time_int <= 60 ));  then ping_score=$((60 - (ping_time_int - 40) / 2))
            elif (( ping_time_int <= 100 )); then ping_score=$((50 - (ping_time_int - 60) / 2))
            elif (( ping_time_int <= 150 )); then ping_score=$((30 - (ping_time_int - 100) / 3))
            elif (( ping_time_int <= 200 )); then ping_score=$((15 - (ping_time_int - 150) / 5))
            else                               ping_score=5
            fi
            if   (( resolution_time_int <= 30 ));  then dns_score=30
            elif (( resolution_time_int <= 50 ));  then dns_score=$((30 - (resolution_time_int - 30) / 4))
            elif (( resolution_time_int <= 80 ));  then dns_score=$((25 - (resolution_time_int - 50) / 6))
            elif (( resolution_time_int <= 120 )); then dns_score=$((20 - (resolution_time_int - 80) / 8))
            elif (( resolution_time_int <= 200 )); then dns_score=$((15 - (resolution_time_int - 120) / 16))
            else                                    dns_score=5
            fi
            (( ping_score < 0 )) && ping_score=0
            (( dns_score  < 0 )) && dns_score=0
            composite_score=$(( ping_score + dns_score ))
        fi
        analysis_results+=("$((100-composite_score))|$dns_name|$dns_server|$avg_resolution_time|$avg_ping_time|$successful_resolutions|$successful_pings|$composite_score")
        echo ""
    done

    echo ""
    echo -e "${CYAN}📊 DNS综合分析结果${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    IFS=$'\n' sorted_results=($(printf '%s\n' "${analysis_results[@]}" | sort -t'|' -k1 -n))

    local rank=1 best_dns="" best_score=""
    local temp_table="/tmp/dns_table_$$"
    echo "DNS服务器|IP地址|解析速度|Ping延迟|综合得分|状态" > "$temp_table"

    for result in "${sorted_results[@]}"; do
        IFS='|' read -r sort_key dns_name dns_server avg_resolution_time avg_ping_time successful_resolutions successful_pings composite_score <<< "$result"
        local display_server="$dns_server"
        [[ ${#dns_server} -gt 18 ]] && display_server="${dns_server:0:15}..."
        local status=""
        if [[ "$composite_score" == "0" ]]; then
            status="失败"
            composite_score="0"
            avg_resolution_time="${avg_resolution_time}ms"
            avg_ping_time="失败"
        else
            avg_resolution_time="${avg_resolution_time}ms"
            avg_ping_time="${avg_ping_time}ms"
            if   (( composite_score >= 95 )); then status="优秀"
            elif (( composite_score >= 85 )); then status="良好"
            elif (( composite_score >= 70 )); then status="一般"
            else                                status="较差"
            fi
        fi
        if (( rank == 1 )) && [[ "$status" != "失败" ]]; then
            best_dns="$dns_name"; best_score="$composite_score"
        fi
        echo "$dns_name|$display_server|$avg_resolution_time|$avg_ping_time|$composite_score|$status" >> "$temp_table"
        ((rank++))
    done

    while IFS='|' read -r dns_name display_server avg_resolution_time avg_ping_time composite_score status; do
        if [[ "$dns_name" == "DNS服务器" ]]; then
            printf "${CYAN}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "优秀"; then
            printf "${GREEN}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "良好"; then
            printf "${YELLOW}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "一般"; then
            printf "${PURPLE}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "较差\|失败"; then
            printf "${RED}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        else
            printf "%-15s %-20s %-12s %-12s %-8s %-8s\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        fi
    done < "$temp_table"
    rm -f "$temp_table"

    echo ""
    echo -e "${CYAN}🏆 综合分析建议${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if [[ -n "$best_dns" ]]; then
        echo -e "${GREEN}🥇 最佳推荐: ${best_dns}${NC}"
        echo -e "   • 综合得分: ${best_score}/100分"
        echo -e "   • 建议: 设置为默认DNS可获得较佳体验"
    else
        echo -e "${RED}❌ 所有DNS测试均失败，请检查网络连接${NC}"
    fi
    echo ""
    echo -e "${GREEN}✅ DNS综合分析完成${NC}"
    echo ""
    echo "按 Enter 键返回主菜单..."
    read -r
}

# 主循环
main() {
    check_dependencies
    while true; do
        show_welcome
        show_menu
        echo -n -e "${YELLOW}请选择 (0-5): ${NC}"
        read -r choice
        [[ -z "$choice" ]] && continue
        case $choice in
            1) run_test ;;
            2) run_dns_test ;;
            3) run_comprehensive_test ;;
            4) run_ip_version_test ;;
            5) run_dns_management ;;
            0)
                echo ""
                echo -e "${GREEN}👋 感谢使用网络延迟检测工具！${NC}"
                echo -e "${CYAN}🌟 项目地址: https://github.com/Cd1s/network-latency-tester${NC}"
                exit 0
                ;;
            *) echo -e "${RED}❌ 无效选择，请输入 0-5${NC}"; if [[ -t 0 ]]; then echo -n -e "${YELLOW}按 Enter 键继续...${NC}"; read -r; else echo -e "${YELLOW}程序结束${NC}"; exit 1; fi ;;
        esac
    done
}

# 运行主程序
main "$@"
