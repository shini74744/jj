#!/usr/bin/env bash
# ==============================================================================
# Linux TCP/IP & BBR 网络优化（无 Swap，支持旧配置迁移）
# 版本：v26.09.15-network-only-migrate
# 基于：https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh
# 网络参数与 v26.09.11-network-only 保持一致；只调整配置迁移及应用流程。
# 不执行交换空间管理命令，不读写 /etc/fstab，不设置 vm.swappiness。
# 迁移仅清理两个已知旧配置文件中的 vm.swappiness 行，不改其当前运行值。
# 配置文件只作为数据解析，绝不作为 Shell 脚本执行。
# 依赖：Bash >= 4、procps sysctl/free、GNU 常用工具、util-linux flock。
# ==============================================================================
set -Eeuo pipefail
umask 077
SCRIPT_VERSION="v26.09.15-network-only-migrate"
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BOLD=$'\033[1m'
NC=$'\033[0m'
BBR_AVAILABLE=false
CONF_WRITE_FILE=""
CONF_FILE="/etc/sysctl.d/99-network-optimization.conf"
LEGACY_CONF_FILE="/etc/sysctl.d/99-bbr.conf"
STATE_DIR="/var/lib/network-optimization"
BACKUP_DIR="$STATE_DIR/backups"
LOCK_FILE="/run/lock/network-optimization.lock"
TX_DIR=""
TX_ACTIVE=false
WORK_DIR=""
MANAGED_BEGIN="# BEGIN network-optimization managed"
MANAGED_END="# END network-optimization managed"
MANAGED_KEYS='net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.core.somaxconn
net.core.netdev_max_backlog
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_timestamps
net.ipv4.tcp_fin_timeout
net.ipv4.ip_local_port_range
net.ipv4.tcp_max_tw_buckets
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_tcp_timeout_established
net.netfilter.nf_conntrack_tcp_timeout_time_wait
fs.file-max
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_syncookies'

success() { printf '  %b✔%b %s\n' "$GREEN" "$NC" "$1"; }
warning() { printf '  %b⚠%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
error() { printf '  %b✗%b %s\n' "$RED" "$NC" "$1" >&2; }
section() { printf '\n%b%s%b\n' "$BOLD" "$1" "$NC"; }
step() { printf '  ▸ %s/%s %s\n' "$1" "$2" "$3"; }
normalize_value() { awk '{$1=$1; print}'; }

require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        error "必须使用 root 权限运行。"
        exit 1
    fi
}

get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt) || VIRT_TYPE=${VIRT_TYPE:-unknown}
    elif grep -q -i "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    else
        VIRT_TYPE="Physical/Unknown"
    fi
    section "系统信息检测"
    printf '%b\n' "  内存大小：${TOTAL_MEM}MB"
    printf '%b\n' "  CPU 核心数：${CPU_CORES}"
    printf '%b\n' "  虚拟化类型：${VIRT_TYPE}"
    calculate_parameters
    printf '%b\n' "  优化档位：${VM_TIER}"
}

calculate_parameters() {
    # 基础连接数设置 - 代理服务器需要更多的连接跟踪
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门级(≤512MB)"
        RMEM_MAX="8388608"    # 8MB
        WMEM_MAX="8388608"
        TCP_MEM_MAX="8388608"
        SOMAXCONN="4096"
        NETDEV_BACKLOG="4096"
        FILE_MAX="131072"
        CONNTRACK_MAX="32768"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        RMEM_MAX="16777216"   # 16MB
        WMEM_MAX="16777216"
        TCP_MEM_MAX="16777216"
        SOMAXCONN="8192"
        NETDEV_BACKLOG="8192"
        FILE_MAX="262144"
        CONNTRACK_MAX="65536"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(1GB-4GB)"
        RMEM_MAX="33554432"   # 32MB
        WMEM_MAX="33554432"
        TCP_MEM_MAX="33554432"
        SOMAXCONN="16384"
        NETDEV_BACKLOG="16384"
        FILE_MAX="524288"
        CONNTRACK_MAX="131072"
    else
        VM_TIER="专业级(>4GB)"
        # 限制最大缓冲区，避免单连接吃光内存，注重并发总量
        RMEM_MAX="67108864"    # 64MB
        WMEM_MAX="67108864"
        TCP_MEM_MAX="67108864"
        SOMAXCONN="32768"
        NETDEV_BACKLOG="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="262144"
    fi
}

sysctl_supported() {
    [[ -e "/proc/sys/${1//./\/}" ]]
}

add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    local target="${CONF_WRITE_FILE:-$CONF_FILE}"
    if ! sysctl_supported "$key"; then
        return 0
    fi
    {
        printf '# %s\n' "$comment" || return 1
        printf '%s = %s\n\n' "$key" "$value"
    } >> "$target"
}

show_optimization_plan() {
    local bbr_status="跳过" conntrack_status="跳过"
    [[ "$BBR_AVAILABLE" = true ]] && bbr_status="启用"
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] && conntrack_status="${CONNTRACK_MAX}"
    printf '%b\n' "${BOLD}  优化参数规划：${NC}"
    printf '  %s：%s\n' "BBR" "$bbr_status"
    printf '  %s：%s\n' "队列算法" "fq（内核支持时配置）"
    printf '  %s：%s\n' "缓冲区上限" "$((RMEM_MAX / 1048576)) MiB"
    printf '  %s：%s\n' "连接队列" "$SOMAXCONN"
    printf '  %s：%s\n' "网卡积压" "$NETDEV_BACKLOG"
    printf '  %s：%s\n' "文件句柄" "$FILE_MAX"
    printf '  %s：%s\n' "Conntrack" "$conntrack_status"
}

apply_optimizations() {
    section "应用网络优化配置：${VM_TIER}"
    # The caller owns the staging file and its cleanup.
    if ! cat > "$CONF_WRITE_FILE" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 管理版本: ${SCRIPT_VERSION}
# 生成时间: $(date)
# 硬件环境: ${TOTAL_MEM}MB RAM, ${CPU_CORES} CPU
# ==========================================================
EOF
    then return 1; fi

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法" || return 1
    if [[ "$BBR_AVAILABLE" = true ]]; then
        add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR" || return 1
    fi
    # 2. 缓冲区优化 (TCP & UDP) - 这对 Hysteria/QUIC 很重要
    add_conf "net.core.rmem_max" "$RMEM_MAX" "系统最大接收缓存" || return 1
    add_conf "net.core.wmem_max" "$WMEM_MAX" "系统最大发送缓存" || return 1
    add_conf "net.core.rmem_default" "262144" "默认接收缓存 (256k)" || return 1
    add_conf "net.core.wmem_default" "262144" "默认发送缓存 (256k)" || return 1
    # TCP 自动调优窗口
    add_conf "net.ipv4.tcp_rmem" "8192 262144 $TCP_MEM_MAX" "TCP读缓存 (min default max)" || return 1
    add_conf "net.ipv4.tcp_wmem" "8192 262144 $TCP_MEM_MAX" "TCP写缓存 (min default max)" || return 1
    add_conf "net.ipv4.udp_rmem_min" "16384" "UDP读缓存下限 (优化QUIC)" || return 1
    add_conf "net.ipv4.udp_wmem_min" "16384" "UDP写缓存下限 (优化QUIC)" || return 1
    # 3. 连接与队列上限
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列" || return 1
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网卡积压队列" || return 1
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN半连接队列" || return 1
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值 (降低延迟)" || return 1
    # 4. TIME_WAIT 与 端口复用 (代理服务器的关键)
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用 (关键优化)" || return 1
    add_conf "net.ipv4.tcp_timestamps" "1" "开启时间戳 (配合 reuse 必须)" || return 1
    add_conf "net.ipv4.tcp_fin_timeout" "30" "缩短 FIN_WAIT 时间" || return 1
    add_conf "net.ipv4.ip_local_port_range" "10000 65535" "扩大本地端口范围" || return 1
    add_conf "net.ipv4.tcp_max_tw_buckets" "500000" "允许更多 TIME_WAIT socket 存在" || return 1
    # 5. TCP Keepalive (快速剔除死链)
    add_conf "net.ipv4.tcp_keepalive_time" "600" "TCP保活时间 (10分钟)" || return 1
    add_conf "net.ipv4.tcp_keepalive_intvl" "15" "探测间隔" || return 1
    add_conf "net.ipv4.tcp_keepalive_probes" "5" "探测次数" || return 1
    # 6. 连接跟踪 (Conntrack，add_conf 会自动跳过不支持的键)
    add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数" || return 1
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)" || return 1
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" "减少 TIME_WAIT 跟踪时间" || return 1
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || warning "当前内核不支持 conntrack，跳过相关参数。"
    # 7. 其他系统级优化
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄" || return 1
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分网络卡顿)" || return 1
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood" || return 1
    return 0
}

# --- 前置检查：不安装软件，不改系统时间，不管理 Swap ---
prepare_environment() {
    require_root
    local cmd path
    if (( BASH_VERSINFO[0] < 4 )); then
        error "需要 Bash 4 或更新版本。"; return 1
    fi
    for cmd in sysctl awk grep mktemp cp mv rm mkdir chmod date find sort cmp flock free nproc cat dirname; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "缺少必要命令：$cmd；请先安装对应的软件包。"; return 1
        fi
    done
    for path in "$CONF_FILE" "$LEGACY_CONF_FILE"; do
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            error "配置路径不是普通文件，停止覆盖：$path"; return 1
        fi
    done
    if [[ -L "$STATE_DIR" || -L "$BACKUP_DIR" || -L "$LOCK_FILE" ]]; then
        error "状态目录或锁文件是符号链接，停止执行。"; return 1
    fi
    mkdir -p -- "$(dirname "$CONF_FILE")" "$(dirname "$LOCK_FILE")" "$BACKUP_DIR"
    chmod 700 -- "$STATE_DIR" "$BACKUP_DIR"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        error "另一个实例正在执行，请勿同时运行。"; return 1
    fi
    WORK_DIR=$(mktemp -d "$STATE_DIR/work.XXXXXX")
    trap 'on_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    recover_pending
}

pre_flight_checks() {
    # 保留原版 BBR/连接跟踪检测，不更改网络调参策略。
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE=true
    else
        warning "当前内核未提供 bbr，将跳过 BBR 配置。"
    fi
}

# --- 只读取本脚本管理的参数；同一文件同一键以最后一项为准 ---
# 兼容空白、行内注释、可选前导 - 以及已知键的 / 分隔写法。
network_targets() {
    awk -v keys="$MANAGED_KEYS" '
    BEGIN { n=split(keys,a,"\n"); for(i=1;i<=n;i++) allowed[a[i]]=1 }
    /^[[:space:]]*($|#|;)/ { next }
    {
        p=index($0,"="); if(!p) next
        k=substr($0,1,p-1); gsub(/[[:space:]]/,"",k); sub(/^-/,"",k); gsub(/\//,".",k)
        if(!(k in allowed)) next
        v=substr($0,p+1); sub(/[[:space:]]*[#;].*$/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
        if(!(k in seen)) { order[++count]=k; seen[k]=1 }
        val[k]=v
    }
    END { for(i=1;i<=count;i++) { k=order[i]; print k "=" val[k] } }
    ' "$1"
}

# 保留旧文件中非本脚本管理的内容，避免整文件删除造成其他配置丢失。
# 两个已知路径中的旧 vm.swappiness 条目只从配置移除，绝不写入运行内核。
# 如果只剩注释/空行，输出空文件；新版标记内的注释不重复累积。
filter_unmanaged() {
    local source="$1" destination="$2"
    if [[ ! -f "$source" ]]; then : > "$destination"; return 0; fi
    awk -v keys="$MANAGED_KEYS" -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    BEGIN { n=split(keys,a,"\n"); for(i=1;i<=n;i++) owned[a[i]]=1; owned["vm.swappiness"]=1 }
    $0==begin { inside=1; next }
    $0==end { inside=0; next }
    {
        raw=$0
        if(raw ~ /^[[:space:]]*($|#|;)/) { if(!inside) text[++count]=raw; next }
        p=index(raw,"=")
        if(p) {
            k=substr(raw,1,p-1); gsub(/[[:space:]]/,"",k); sub(/^-/,"",k); gsub(/\//,".",k)
            if(k in owned) next
        }
        text[++count]=raw; active++
    }
    END { if(active) { while(count>0 && text[count] ~ /^[[:space:]]*$/) count--; for(i=1;i<=count;i++) print text[i] } }
    ' "$source" > "$destination"
}

# --- 迁移摘要：读取已知旧配置，但不执行其中任何内容 ---
show_migration() {
    local path data count found=false
    section "读取旧配置与迁移规划"
    for path in "$LEGACY_CONF_FILE" "$CONF_FILE"; do
        [[ -f "$path" ]] || continue
        found=true
        data=$(network_targets "$path")
        count=$(awk 'NF {n++} END {print n+0}' <<< "$data")
        printf '  检测到：%s（%s 个托管网络参数）\n' "$path" "$count"
        if awk '
            /^[[:space:]]*($|#|;)/ {next}
            {p=index($0,"="); if(!p) next; k=substr($0,1,p-1); gsub(/[[:space:]]/,"",k);
             sub(/^-/,"",k); gsub(/\//,".",k); if(k=="vm.swappiness") found=1}
            END {exit !found}' "$path"; then
            printf '  将移除该文件中的旧 vm.swappiness 配置行，不修改当前运行值。\n'
        fi
    done
    if [[ "$found" == false ]]; then
        printf '  未检测到两个已知路径下的旧配置，按首次安装处理。\n'
    else
        printf '  先完整备份；同名网络参数以本次目标值覆盖；无关配置保留。\n'
    fi
}

# --- 原子替换：临时文件与目标处于同一目录 ---
atomic_copy() {
    local source="$1" destination="$2" tmp
    tmp=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! cp -p -- "$source" "$tmp" || ! mv -f -- "$tmp" "$destination"; then
        rm -f -- "$tmp"; return 1
    fi
}

set_tx_status() {
    printf '%s\n' "$1" > "$TX_DIR/status.new" && mv -f -- "$TX_DIR/status.new" "$TX_DIR/status"
}

# 每次操作保留配置原件和目标参数的运行快照，不自动删除旧备份。
# 备份不是 .conf 文件，也不会被作为系统配置重新加载。
begin_transaction() {
    local targets="$1" operation="$2" path name key value actual
    TX_DIR=$(mktemp -d "$BACKUP_DIR/$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    printf '%s\n' "$operation" > "$TX_DIR/operation"
    printf '%s\n' "$SCRIPT_VERSION" > "$TX_DIR/version"
    set_tx_status preparing || return 1
    for name in main legacy; do
        if [[ "$name" == main ]]; then path="$CONF_FILE"; else path="$LEGACY_CONF_FILE"; fi
        if [[ -f "$path" ]]; then
            cp -p -- "$path" "$TX_DIR/$name.before" || return 1
            : > "$TX_DIR/$name.present"
        else
            : > "$TX_DIR/$name.absent"
        fi
    done
    cp -- "$targets" "$TX_DIR/network.apply" || return 1
    : > "$TX_DIR/runtime.before"
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        if ! actual=$(sysctl -n "$key" 2>"$TX_DIR/read-error.log"); then
            error "无法保存当前参数：$key；尚未覆盖配置。"
            cat "$TX_DIR/read-error.log" >&2
            return 1
        fi
        printf '%s=%s\n' "$key" "$(normalize_value <<< "$actual")" >> "$TX_DIR/runtime.before" || return 1
    done < "$targets"
    printf '  备份目录：%s\n' "$TX_DIR"
}

# 提交前再检查文件内容，避免迁移过程中静默覆盖其他程序刚写入的修改。
check_files_unchanged() {
    local name path
    for name in main legacy; do
        if [[ "$name" == main ]]; then path="$CONF_FILE"; else path="$LEGACY_CONF_FILE"; fi
        if [[ -f "$TX_DIR/$name.present" ]]; then
            if [[ -L "$path" ]] || ! cmp -s -- "$TX_DIR/$name.before" "$path"; then
                error "配置在备份后发生变化，取消覆盖：$path"; return 1
            fi
        elif [[ -e "$path" || -L "$path" ]]; then
            error "配置在备份后被创建，取消覆盖：$path"; return 1
        fi
    done
}

# 失败仅恢复本次操作涉及的两个文件和目标网络参数，不重新加载全系统配置。
rollback_transaction() {
    local name path key value actual failed=0
    warning "正在恢复本次操作前的配置及目标网络参数……"
    for name in main legacy; do
        if [[ "$name" == main ]]; then path="$CONF_FILE"; else path="$LEGACY_CONF_FILE"; fi
        if [[ -f "$TX_DIR/$name.present" && -f "$TX_DIR/$name.before" ]]; then
            if ! atomic_copy "$TX_DIR/$name.before" "$path"; then
                error "配置恢复失败：$path"; failed=1
            fi
        elif [[ -f "$TX_DIR/$name.absent" ]]; then
            if ! rm -f -- "$path"; then error "无法撤销新配置：$path"; failed=1; fi
        else
            error "备份状态不完整：$name"; failed=1
        fi
    done
    if [[ ! -f "$TX_DIR/runtime.before" ]]; then
        error "缺少运行值快照：$TX_DIR"; failed=1
    else
        while IFS='=' read -r key value; do
            [[ -n "$key" ]] || continue
            actual=$(sysctl -n "$key" 2>/dev/null) || actual=""
            if [[ "$(normalize_value <<< "$actual")" == "$(normalize_value <<< "$value")" ]]; then continue; fi
            if ! sysctl -w "$key=$value" >>"$TX_DIR/rollback.log" 2>&1; then
                warning "运行值恢复失败：$key"; failed=1; continue
            fi
            actual=$(sysctl -n "$key" 2>/dev/null) || actual=""
            if [[ "$(normalize_value <<< "$actual")" != "$(normalize_value <<< "$value")" ]]; then
                warning "运行值恢复验证失败：$key"; failed=1
            fi
        done < "$TX_DIR/runtime.before"
    fi
    if [[ "$failed" -eq 0 ]]; then
        set_tx_status rolled-back || return 1
        success "已恢复本次操作前的配置及目标网络参数。"
        return 0
    fi
    set_tx_status rollback-failed || true
    error "恢复未完全成功；备份和日志保留于：$TX_DIR"
    return 1
}

on_exit() {
    local rc="$1"
    trap - EXIT INT TERM HUP
    if [[ "$TX_ACTIVE" == true ]]; then
        [[ "$rc" -ne 0 ]] || rc=1
        rollback_transaction || rc=1
    fi
    if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR" || true; fi
    exit "$rc"
}

# INT/TERM/HUP 由退出处理恢复；强制终止/断电后在下次运行检查持久化状态。
recover_pending() {
    local directory status
    while IFS= read -r directory; do
        [[ -f "$directory/status" ]] || continue
        status=$(<"$directory/status")
        case "$status" in
            in-progress|rollback-failed)
                TX_DIR="$directory"
                warning "检测到未完成的操作：$directory"
                if ! rollback_transaction; then
                    error "请检查备份和日志；未继续执行新的迁移。"; return 1
                fi
                ;;
        esac
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort)
    TX_DIR=""
}

# 逐项设置并读回；只写本脚本管理的网络键，绝不使用 sysctl --system。
apply_and_verify() {
    local key value actual rc=0
    section "应用并验证网络参数"
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        actual=$(sysctl -n "$key" 2>/dev/null) || actual=""
        if [[ "$(normalize_value <<< "$actual")" == "$(normalize_value <<< "$value")" ]]; then continue; fi
        if ! sysctl -w "$key=$value" >>"$TX_DIR/apply.log" 2>&1; then
            error "设置失败：$key = $value"
            cat "$TX_DIR/apply.log" >&2
            return 1
        fi
    done < "$TX_DIR/network.apply"
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        actual=$(sysctl -n "$key" 2>/dev/null) || actual=""
        if [[ "$(normalize_value <<< "$actual")" != "$(normalize_value <<< "$value")" ]]; then
            error "验证失败：$key（目标：$value；实际：${actual:-无法读取}）"
            rc=1
        fi
    done < "$TX_DIR/network.apply"
    return "$rc"
}

# --- 安装/迁移同一事务：主文件覆盖更新；旧 99-bbr.conf 仅移走托管项 ---
install_candidate() {
    local candidate="$1" operation="$2"
    network_targets "$candidate" > "$WORK_DIR/targets"
    if [[ ! -s "$WORK_DIR/targets" ]]; then error "没有可应用的网络参数。"; return 1; fi
    show_migration
    begin_transaction "$WORK_DIR/targets" "$operation"
    filter_unmanaged "$TX_DIR/main.before" "$WORK_DIR/main.extra"
    filter_unmanaged "$TX_DIR/legacy.before" "$WORK_DIR/legacy.after"
    {
        if [[ -s "$WORK_DIR/main.extra" ]]; then
            cat "$WORK_DIR/main.extra"
            printf '\n'
        fi
        printf '%s\n' "$MANAGED_BEGIN"
        cat "$candidate"
        printf '\n%s\n' "$MANAGED_END"
    } > "$WORK_DIR/main.after"
    chmod 644 "$WORK_DIR/main.after" "$WORK_DIR/legacy.after"
    check_files_unchanged
    set_tx_status in-progress
    TX_ACTIVE=true
    atomic_copy "$WORK_DIR/main.after" "$CONF_FILE"
    if [[ -f "$TX_DIR/legacy.present" ]]; then
        if [[ -s "$WORK_DIR/legacy.after" ]]; then
            atomic_copy "$WORK_DIR/legacy.after" "$LEGACY_CONF_FILE"
            success "旧 99-bbr.conf 的托管参数已迁移；其余配置保留。"
        else
            rm -f -- "$LEGACY_CONF_FILE"
            success "旧 99-bbr.conf 已备份并移出生效位置。"
        fi
    fi
    apply_and_verify
    set_tx_status success
    TX_ACTIVE=false
    success "配置已迁移覆盖，目标网络参数已逐项验证。"
    printf '  配置文件：%s\n  备份目录：%s\n' "$CONF_FILE" "$TX_DIR"
    printf '  仅更新上述已知路径；其他文件中的同名配置未改动，可能在后续加载时覆盖。\n'
    printf '  不改变已有交换空间、挂载配置或 vm.swappiness 当前值。\n'
}

configure_network() {
    CONF_WRITE_FILE="$WORK_DIR/generated.conf"
    apply_optimizations
    CONF_WRITE_FILE=""
    install_candidate "$WORK_DIR/generated.conf" apply
}

# --- 恢复兼容：本版本备份优先；兼容旧 .bak_* / .migrated_* 文件 ---
# 恢复的是网络参数，不会把旧备份里的 Swap 设置重新应用。
restore_network() {
    local directory chosen="" backup="" key value
    while IFS= read -r directory; do
        [[ -f "$directory/status" && -f "$directory/operation" ]] || continue
        if [[ "$(<"$directory/status")" == success && "$(<"$directory/operation")" == apply ]]; then
            chosen="$directory"; break
        fi
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{sub(/^[^ ]+ /, ""); print}')
    : > "$WORK_DIR/restore.source"
    if [[ -n "$chosen" ]]; then
        # 运行快照填补旧文件中未显式设置的键；旧主文件对旧 legacy 文件优先。
        cat "$chosen/runtime.before" >> "$WORK_DIR/restore.source"
        if [[ -f "$chosen/legacy.before" ]]; then network_targets "$chosen/legacy.before" >> "$WORK_DIR/restore.source"; fi
        if [[ -f "$chosen/main.before" ]]; then network_targets "$chosen/main.before" >> "$WORK_DIR/restore.source"; fi
        printf '  恢复来源：%s\n' "$chosen"
    else
        backup=$(find "$(dirname "$CONF_FILE")" -maxdepth 1 -type f \
            \( -name "$(basename "$CONF_FILE").bak_*" -o -name "$(basename "$LEGACY_CONF_FILE").migrated_*" \) \
            -printf '%T@ %p\n' | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print}')
        if [[ -z "$backup" ]]; then error "未找到可恢复的备份。"; return 1; fi
        network_targets "$backup" > "$WORK_DIR/restore.source"
        printf '  兼容旧备份：%s\n' "$backup"
    fi
    network_targets "$WORK_DIR/restore.source" > "$WORK_DIR/restore.targets"
    printf '# 恢复的网络配置，版本 %s\n' "$SCRIPT_VERSION" > "$WORK_DIR/restore.conf"
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        if sysctl_supported "$key"; then
            printf '%s = %s\n' "$key" "$value" >> "$WORK_DIR/restore.conf"
        else
            warning "当前内核没有该参数，恢复时跳过：$key"
        fi
    done < "$WORK_DIR/restore.targets"
    install_candidate "$WORK_DIR/restore.conf" restore
}

# 卸载只移除主文件中本脚本管理的持久化项；无关条目保留。
# 不重新加载全系统配置，也不假装恢复默认值。需要恢复时请先执行 restore。
uninstall_network() {
    section "卸载托管网络配置"
    warning "仅移除持久化配置；当前运行参数保持不变，不恢复内核默认值。"
    if [[ ! -f "$CONF_FILE" ]]; then success "未发现本脚本主配置，无需卸载。"; return 0; fi
    : > "$WORK_DIR/empty.targets"
    begin_transaction "$WORK_DIR/empty.targets" uninstall
    filter_unmanaged "$TX_DIR/main.before" "$WORK_DIR/uninstall.after"
    chmod 644 "$WORK_DIR/uninstall.after"
    check_files_unchanged
    set_tx_status in-progress
    TX_ACTIVE=true
    if [[ -s "$WORK_DIR/uninstall.after" ]]; then
        atomic_copy "$WORK_DIR/uninstall.after" "$CONF_FILE"
        success "本脚本托管配置已移除，无关条目仍保留。"
    else
        rm -f -- "$CONF_FILE"
        success "本脚本主配置已删除。"
    fi
    set_tx_status success
    TX_ACTIVE=false
    printf '  备份目录：%s\n' "$TX_DIR"
}

usage() {
    cat <<EOF
VPS 网络优化 ${SCRIPT_VERSION}

用法：
  bash $0             应用原有网络参数，读取、备份并迁移覆盖旧配置
  bash $0 restore     恢复最近成功应用前的网络配置，兼容旧版备份
  bash $0 uninstall   仅移除托管持久化配置，不恢复当前运行值
  bash $0 --help      显示帮助（不需要 root）

自动迁移范围：
  $CONF_FILE
  $LEGACY_CONF_FILE

规则：
  网络参数和内存分档保持原版；同名托管参数由新版本覆盖，不重复追加。
  非托管配置保留；旧 vm.swappiness 行从这两个文件移除，但不改运行值。
  不创建、关闭或删除交换空间，不读写挂载配置。
  只应用本脚本的网络参数，不重新加载全系统 sysctl 配置。
  每次修改前完整备份两个旧文件和目标网络运行值；失败尝试自动恢复。
  restore 只恢复网络参数，不重新启用旧版 Swap 逻辑，也不撤销迁移布局。
  uninstall 不删除备份，不复原 legacy 文件，不自动恢复内核默认值。
  首次迁移前旧版已改变的系统状态无法由新脚本推断或自动复原。
  其他路径中的配置不自动清理；备份位于 $BACKUP_DIR，需自行管理占用。
EOF
}

main() {
    if [[ $# -gt 1 ]]; then error "只接受一个操作参数。"; usage >&2; return 2; fi
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        "") if [[ $# -ne 0 ]]; then error "不接受空参数。"; return 2; fi ;;
        restore|uninstall) ;;
        *) error "未知参数：$1"; usage >&2; return 2 ;;
    esac
    printf '%bVPS 网络优化 %s%b\n' "$BOLD" "$SCRIPT_VERSION" "$NC"
    prepare_environment
    case "${1:-}" in
        restore) restore_network ;;
        uninstall) uninstall_network ;;
        "")
            pre_flight_checks
            get_system_info
            if [[ ! "$TOTAL_MEM" =~ ^[0-9]+$ || "$TOTAL_MEM" -le 0 ]]; then
                error "无法取得有效内存大小，未应用配置。"; return 1
            fi
            show_optimization_plan
            configure_network
            ;;
    esac
}

# 便于只加载函数进行隔离测试；直接执行脚本时进入主流程。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
