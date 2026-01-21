#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector 菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 功能：
#   1) 安装 / 配置 Fail2ban 仅用于 SSH 防爆破
#      - 安装时输入 SSH 端口（回车默认 22）
#      - 自动把当前 SSH 来源 IP 加入 ignoreip 白名单（避免误封自己）
#      - 同时把当前 SSH 来源 IP 写入“SSH 连接白名单文件”（菜单7可见）
#      - 安装完成后自动安装 fb5 命令：/usr/local/bin/fb5
#   2) 快捷修改 SSH 防爆破参数（maxretry / bantime / findtime）
#   3) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#   4) 从远程更新 fb5 脚本（仅更新功能：下载覆盖并赋权）
#   5) 查看当前封禁 IP 列表（sshd jail）
#   6) 解禁指定 IP（sshd jail）
#   7) SSH 连接白名单（只允许白名单 IP 连接 SSH；支持追加/删除/关闭）
#      - 新增/删除后立即生效
#      - 进入菜单7时会自动把当前 SSH 来源 IP 同步进白名单文件
#      - 端口自动探测 + 可选覆盖（进入菜单7只问一次）
#      - 持久化：方案A写入系统原生（尽力而为）
#      - 兜底：方案B systemd 服务【始终启用】(只要白名单启用)，保证重启后必定重新下发规则
#
# 默认策略（首次安装 / 无 [sshd] 参数时）：
#   - maxretry = 3
#   - findtime = 21600（6小时）
#   - bantime  = 12h
# ============================================================

set -e

#-----------------------------
# 公共变量
#-----------------------------
OS=""
FIREWALL=""
JAIL="/etc/fail2ban/jail.local"
INSTALL_CMD_PATH="/usr/local/bin/fb5"
REMOTE_URL="https://raw.githubusercontent.com/shini74744/jj/refs/heads/main/fb5.sh"

# SSH 白名单
ALLOWLIST_DIR="/etc/fb5"
ALLOWLIST_FILE="${ALLOWLIST_DIR}/ssh_allowlist.txt"
ALLOWLIST_ENABLED_FLAG="${ALLOWLIST_DIR}/ssh_allowlist_enabled"
SSH_PORT_OVERRIDE_FILE="${ALLOWLIST_DIR}/ssh_port_override"
IPTABLES_CHAIN="FB5_SSH_ALLOW"

# nftables 持久化
NFT_TABLE="fb5"
NFT_FAMILY="inet"
NFT_PERSIST_DIR="/etc/nftables.d"
NFT_PERSIST_FILE="${NFT_PERSIST_DIR}/fb5-ssh-allow.nft"
NFT_MAIN_CONF="/etc/nftables.conf"

# firewalld
FIREWALLD_IPSET="fb5-ssh-allow"

# systemd 兜底（方案B）
SYSTEMD_UNIT="/etc/systemd/system/fb5-ssh-allowlist.service"

#-----------------------------
# 工具函数
#-----------------------------
pause() { read -rp "按 Enter 返回菜单..." _; }

ensure_root() {
    if [[ ${EUID:-0} -ne 0 ]]; then
        echo "❌ 请使用 root 权限运行此脚本"
        exit 1
    fi
}

detect_os() {
    if [[ -n "$OS" ]]; then return; fi

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release || true
        case "${ID:-}" in
            ubuntu) OS="ubuntu" ;;
            debian) OS="debian" ;;
            centos) OS="centos" ;;
            rhel)   OS="rhel" ;;
            rocky)  OS="rocky" ;;
            almalinux) OS="almalinux" ;;
            fedora) OS="fedora" ;;
            *) ;;
        esac

        if [[ -z "$OS" ]]; then
            if grep -qiE "debian|ubuntu" <<<"${ID_LIKE:-}"; then
                OS="debianlike"
            elif grep -qiE "rhel|fedora|centos" <<<"${ID_LIKE:-}"; then
                OS="rhellike"
            fi
        fi

        [[ -n "$OS" ]] && return
    fi

    if [[ -f /etc/redhat-release ]]; then
        OS="rhellike"
    else
        OS="unknown"
    fi
}

detect_firewall() {
    if [[ -n "$FIREWALL" ]]; then return; fi
    if command -v firewall-cmd &>/dev/null; then
        FIREWALL="firewalld"
    elif command -v nft &>/dev/null; then
        FIREWALL="nftables"
    else
        FIREWALL="iptables"
    fi
}

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

#-----------------------------
# 包管理器：探测 / 修复 / 安装（稳健）
#-----------------------------
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "unknown"
    fi
}

wait_for_apt_locks() {
    local max_wait="${1:-180}"
    local waited=0
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if (( waited >= max_wait )); then
            echo "⚠ apt/dpkg 锁仍被占用（等待 ${max_wait}s 超时）。将继续尝试后续流程。"
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 0
}

fix_pkg_mgr_apt() {
    echo "📦 [APT] 尝试修复 dpkg/apt 状态（尽力而为，不阻断主流程）..."
    wait_for_apt_locks 180 || true
    dpkg --configure -a || true
    apt-get -y -f install || true
    apt-get -y clean || true
    for i in 1 2; do
        if apt-get update -y; then
            echo "✅ [APT] apt-get update 成功"
            break
        fi
        echo "⚠ [APT] apt-get update 失败，重试 ${i}/2 ..."
        sleep 2
    done
    apt-get -y -f install || true
    echo "✅ [APT] 修复流程已执行完成"
    return 0
}

fix_pkg_mgr_yum_dnf() {
    local pm="$1"
    echo "📦 [${pm}] 尝试修复 yum/dnf 状态（尽力而为，不阻断主流程）..."
    if [[ "$pm" == "dnf" ]]; then
        dnf -y clean all || true
        dnf -y makecache || true
    else
        yum -y clean all || true
        yum -y makecache || true
    fi

    if command -v yum-complete-transaction >/dev/null 2>&1; then
        yum-complete-transaction -y || true
    elif [[ "$pm" == "dnf" ]]; then
        dnf -y distro-sync || true
    fi

    if command -v rpm >/dev/null 2>&1; then
        rpm --rebuilddb >/dev/null 2>&1 || true
    fi

    echo "✅ [${pm}] 修复流程已执行完成"
    return 0
}

fix_pkg_mgr() {
    local pm
    pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt) fix_pkg_mgr_apt ;;
        dnf) fix_pkg_mgr_yum_dnf "dnf" ;;
        yum) fix_pkg_mgr_yum_dnf "yum" ;;
        *) echo "⚠ 未识别到可用包管理器（apt/dnf/yum），跳过自动修复。"; return 1 ;;
    esac
}

install_pkgs() {
    local pm
    pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt)
            wait_for_apt_locks 180 || true
            apt-get update -y || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
                echo "⚠ [APT] 安装失败，尝试修复后重试一次..."
                fix_pkg_mgr_apt || true
                wait_for_apt_locks 180 || true
                apt-get update -y || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            fi
            ;;
        dnf)
            if ! dnf -y install "$@"; then
                echo "⚠ [DNF] 安装失败，尝试修复后重试一次..."
                fix_pkg_mgr_yum_dnf "dnf" || true
                dnf -y install "$@"
            fi
            ;;
        yum)
            if ! yum -y install "$@"; then
                echo "⚠ [YUM] 安装失败，尝试修复后重试一次..."
                fix_pkg_mgr_yum_dnf "yum" || true
                yum -y install "$@"
            fi
            ;;
        *) echo "❌ 无法安装：未找到 apt/dnf/yum"; return 1 ;;
    esac
}

ensure_curl() {
    if command -v curl &>/dev/null; then return; fi
    echo "📦 未检测到 curl，正在安装..."
    fix_pkg_mgr || true
    install_pkgs curl
}

#-----------------------------
# Fail2ban / SSH 防爆破
#-----------------------------
get_action_for_firewall() {
    detect_firewall
    case "$FIREWALL" in
        nftables) echo "nftables-multiport" ;;
        firewalld) echo "firewallcmd-ipset" ;;
        *) echo "iptables-multiport" ;;
    esac
}

pick_ssh_logpath() {
    local paths=()
    [[ -f /var/log/auth.log ]] && paths+=("/var/log/auth.log")
    [[ -f /var/log/secure ]] && paths+=("/var/log/secure")
    if (( ${#paths[@]} == 0 )); then
        echo "/var/log/auth.log /var/log/secure"
        return
    fi
    echo "${paths[*]}"
}

prompt_ssh_port() {
    local p=""
    while true; do
        read -rp "请输入 SSH 端口号（回车默认 22）: " p
        if [[ -z "$p" ]]; then echo "22"; return; fi
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
            echo "$p"; return
        fi
        echo "⚠ 端口号无效，请输入 1-65535 的整数，或直接回车默认 22。"
    done
}

get_sshd_value() {
    local key="$1"
    awk -v k="$key" '
        BEGIN{in_sshd=0}
        /^\[sshd\]/{in_sshd=1; next}
        /^\[.*\]/{if(in_sshd){in_sshd=0}}
        in_sshd {
            if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", $0)
                sub("[[:space:]]*$", "", $0)
                print $0
            }
        }
    ' "$JAIL" 2>/dev/null | tail -n1
}

rewrite_or_append_sshd_block() {
    local port="$1" action="$2" logpath="$3" maxretry="$4" findtime="$5" bantime="$6"

    if [[ ! -f "$JAIL" ]]; then
        mkdir -p /etc/fail2ban
        touch "$JAIL"
    fi

    if ! grep -q "^\[sshd\]" "$JAIL"; then
        cat >> "$JAIL" <<EOF

[sshd]
enabled  = true
port     = $port
filter   = sshd
action   = $action
logpath  = $logpath
maxretry = $maxretry
findtime = $findtime
bantime  = $bantime
EOF
        return
    fi

    local tmpfile
    tmpfile="$(mktemp)"
    awk -v port="$port" -v action="$action" -v logpath="$logpath" \
        -v maxretry="$maxretry" -v findtime="$findtime" -v bantime="$bantime" '
        BEGIN{in_sshd=0; printed=0}
        /^\[sshd\]/{
            if(!printed){
                print "[sshd]"
                print "enabled  = true"
                print "port     = " port
                print "filter   = sshd"
                print "action   = " action
                print "logpath  = " logpath
                print "maxretry = " maxretry
                print "findtime = " findtime
                print "bantime  = " bantime
                printed=1
            }
            in_sshd=1
            next
        }
        /^\[.*\]/{ in_sshd=0 }
        { if(!in_sshd) print }
    ' "$JAIL" > "$tmpfile" && mv "$tmpfile" "$JAIL"
}

#-----------------------------
# SSH 来源 IP 与会话端口获取
#-----------------------------
get_current_ssh_client_ip() {
    if [[ -n "${SSH_CONNECTION-}" ]]; then
        awk '{print $1}' <<<"$SSH_CONNECTION"; return 0
    fi
    if [[ -n "${SSH_CLIENT-}" ]]; then
        awk '{print $1}' <<<"$SSH_CLIENT"; return 0
    fi
    return 1
}

get_current_session_ssh_port() {
    # SSH_CONNECTION: "clientip clientport serverip serverport"
    if [[ -n "${SSH_CONNECTION-}" ]]; then
        awk '{print $4}' <<<"$SSH_CONNECTION" | grep -E '^[0-9]+$' || true
        return 0
    fi
    return 1
}

#-----------------------------
# Fail2ban ignoreip 白名单
#-----------------------------
add_ip_to_ignoreip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        echo "⚠ 检测到的来源 IP 看起来不合法，跳过 ignoreip：$ip"
        return 1
    fi

    mkdir -p /etc/fail2ban

    if [[ ! -f "$JAIL" ]]; then
        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $ip
EOF
        echo "✅ 已将当前 SSH 来源 IP 加入 ignoreip：$ip"
        return 0
    fi

    if ! grep -q "^\[DEFAULT\]" "$JAIL"; then
        local tmpf; tmpf="$(mktemp)"
        {
            echo "[DEFAULT]"
            echo "ignoreip = 127.0.0.1/8 $ip"
            echo ""
            cat "$JAIL"
        } > "$tmpf" && mv "$tmpf" "$JAIL"
        echo "✅ 已将当前 SSH 来源 IP 加入 ignoreip：$ip"
        return 0
    fi

    local tmpfile; tmpfile="$(mktemp)"
    awk -v ip="$ip" '
        function has_ip(line, x){
            return (index(" " line " ", " " x " ") > 0)
        }
        BEGIN{in_def=0; has_ignore=0}
        /^\[DEFAULT\]$/ {in_def=1; print; next}
        /^\[/ && $0 !~ /^\[DEFAULT\]$/ {
            if(in_def && has_ignore==0){
                print "ignoreip = 127.0.0.1/8 " ip
            }
            in_def=0
            print
            next
        }
        {
            if(in_def && $0 ~ /^ignoreip[[:space:]]*=/){
                has_ignore=1
                if(has_ip($0, ip)){
                    print
                } else {
                    print $0 " " ip
                }
                next
            }
            print
        }
        END{
            if(in_def && has_ignore==0){
                print "ignoreip = 127.0.0.1/8 " ip
            }
        }
    ' "$JAIL" > "$tmpfile" && mv "$tmpfile" "$JAIL"

    echo "✅ 已将当前 SSH 来源 IP 加入/确认在 ignoreip：$ip"
    return 0
}

#-----------------------------
# fb5 安装
#-----------------------------
install_fb5_now() {
    mkdir -p "$(dirname "$INSTALL_CMD_PATH")"

    local src="$0"
    if command -v readlink &>/dev/null; then
        src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    fi

    if [[ -f "$src" ]]; then
        cp -f "$src" "$INSTALL_CMD_PATH"
        chmod +x "$INSTALL_CMD_PATH"
        echo "✅ 已安装 fb5 命令：$INSTALL_CMD_PATH（来源：当前脚本）"
        return 0
    fi

    ensure_curl
    if curl -fsSL "$REMOTE_URL" -o "$INSTALL_CMD_PATH"; then
        chmod +x "$INSTALL_CMD_PATH"
        echo "✅ 已安装 fb5 命令：$INSTALL_CMD_PATH（来源：远程下载）"
        return 0
    fi

    echo "⚠ fb5 安装失败：无法从当前脚本复制，也无法从远程下载。"
    return 1
}

#-----------------------------
# Fail2ban 状态检查（用于 5/6）
#-----------------------------
ensure_fail2ban_ready() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "❌ 未检测到 fail2ban-client（Fail2ban 可能未安装）。"
        return 1
    fi
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active --quiet fail2ban; then
            echo "❌ Fail2ban 当前未运行（fail2ban 服务未 active）。"
            echo "   可尝试：systemctl restart fail2ban"
            return 1
        fi
    fi
    if ! fail2ban-client status sshd &>/dev/null; then
        echo "❌ sshd jail 未启用或无法查询。"
        echo "   请先执行菜单 1 安装/配置 SSH 防爆破。"
        return 1
    fi
    return 0
}

#-----------------------------
# 5. 查看封禁 IP（sshd）
#-----------------------------
view_banned_ips() {
    if ! ensure_fail2ban_ready; then pause; return; fi
    echo "================ sshd 当前封禁 IP ================"
    if fail2ban-client get sshd banip &>/dev/null; then
        local ips
        ips="$(fail2ban-client get sshd banip | tr -s ' ' | sed 's/^ *//;s/ *$//')"
        if [[ -z "$ips" ]]; then
            echo "✅ 当前无封禁 IP"
        else
            echo "$ips" | tr ' ' '\n'
        fi
    else
        echo "（当前 fail2ban-client 不支持 get banip，改用 status 输出）"
        fail2ban-client status sshd || true
    fi
    echo "=================================================="
    echo ""
    pause
}

#-----------------------------
# 6. 解禁指定 IP（sshd）
#-----------------------------
unban_ip() {
    if ! ensure_fail2ban_ready; then pause; return; fi

    local ip=""
    read -rp "请输入要解禁的 IP（IPv4/IPv6，回车取消）: " ip
    if [[ -z "$ip" ]]; then echo "已取消。"; pause; return; fi
    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        echo "⚠ IP 格式看起来不正确：$ip"
        pause
        return
    fi

    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        echo "✅ 已解禁：$ip"
    else
        echo "❌ 解禁失败：$ip"
        echo "   可能原因：该 IP 不在封禁列表中，或 fail2ban 运行异常。"
    fi
    echo ""
    pause
}

#-----------------------------
# 状态总览
#-----------------------------
print_status_summary() {
    echo "---------------- 当前运行状态 ----------------"
    local fb_status="未知" fb_enabled="未知" sshd_jail="未知"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet fail2ban; then fb_status="运行中"; else fb_status="未运行"; fi
        if systemctl is-enabled --quiet fail2ban 2>/dev/null; then fb_enabled="是"; else fb_enabled="否"; fi
    else
        fb_status="未知（无 systemd）"; fb_enabled="未知"
    fi

    if command -v fail2ban-client &>/dev/null && command -v systemctl &>/dev/null && systemctl is-active --quiet fail2ban; then
        if fail2ban-client status sshd &>/dev/null; then sshd_jail="已启用"; else sshd_jail="未启用"; fi
    elif ! command -v fail2ban-client &>/dev/null; then
        sshd_jail="未知（未安装 Fail2ban）"
    else
        sshd_jail="未知（Fail2ban 未运行）"
    fi

    local show_port="—"
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        show_port="$(get_sshd_value port)"
        [[ -z "$show_port" ]] && show_port="—"
    fi

    local fb5_status="未安装"
    [[ -x "$INSTALL_CMD_PATH" ]] && fb5_status="已安装($INSTALL_CMD_PATH)"

    local allow_status="未启用"
    if [[ -f "$ALLOWLIST_ENABLED_FLAG" ]]; then
        allow_status="已启用"
    elif [[ -f "$ALLOWLIST_FILE" ]] && [[ -s "$ALLOWLIST_FILE" ]]; then
        allow_status="已配置(未启用)"
    fi

    local override_port="自动"
    if [[ -f "$SSH_PORT_OVERRIDE_FILE" ]]; then
        local v; v="$(cat "$SSH_PORT_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$v" =~ ^[0-9]+$ ]]; then override_port="$v"; fi
    fi

    local b_fallback="未知"
    if have_systemd; then
        if [[ -f "$SYSTEMD_UNIT" ]]; then
            if systemctl is-enabled --quiet fb5-ssh-allowlist 2>/dev/null; then
                b_fallback="已启用"
            else
                b_fallback="已安装(未启用)"
            fi
        else
            b_fallback="未安装"
        fi
    else
        b_fallback="不可用(无systemd)"
    fi

    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 端口(记录于 fail2ban): $show_port"
    echo "快捷命令: $fb5_status"
    echo "SSH 白名单: $allow_status"
    echo "白名单端口覆盖: $override_port"
    echo "白名单兜底(B): $b_fallback"
    echo "------------------------------------------------"
    echo ""
}

# ============================================================
# 7. SSH 连接白名单（只允许白名单 IP 连接 SSH）
# ============================================================

ensure_allowlist_storage() {
    mkdir -p "$ALLOWLIST_DIR"
    touch "$ALLOWLIST_FILE"
    chmod 600 "$ALLOWLIST_FILE" || true
}

is_valid_ip_or_cidr() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" =~ [[:space:]] ]] && return 1
    [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]] || return 1
    return 0
}

allowlist_add_ip() {
    local ip="$1"
    ensure_allowlist_storage
    is_valid_ip_or_cidr "$ip" || return 1
    if grep -Fxq "$ip" "$ALLOWLIST_FILE"; then return 0; fi
    echo "$ip" >> "$ALLOWLIST_FILE"
    sort -u "$ALLOWLIST_FILE" -o "$ALLOWLIST_FILE" || true
    return 0
}

allowlist_del_ip() {
    local ip="$1"
    ensure_allowlist_storage
    grep -Fxq "$ip" "$ALLOWLIST_FILE" || return 1
    grep -Fxv "$ip" "$ALLOWLIST_FILE" > "${ALLOWLIST_FILE}.tmp" && mv "${ALLOWLIST_FILE}.tmp" "$ALLOWLIST_FILE"
    return 0
}

sync_current_ssh_ip_to_allowlist() {
    ensure_allowlist_storage
    local cur=""
    cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
    if [[ -n "$cur" ]]; then
        allowlist_add_ip "$cur" >/dev/null 2>&1 || true
    fi
}

allowlist_show() {
    ensure_allowlist_storage
    echo "================ SSH 白名单列表 ================"
    if [[ ! -s "$ALLOWLIST_FILE" ]]; then
        echo "（当前为空）"
    else
        nl -ba "$ALLOWLIST_FILE"
    fi
    echo "==============================================="
}

read_ssh_port_override() {
    if [[ -f "$SSH_PORT_OVERRIDE_FILE" ]]; then
        local v
        v="$(cat "$SSH_PORT_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )); then
            echo "$v"
            return 0
        fi
    fi
    return 1
}

write_ssh_port_override() {
    local v="$1"
    ensure_allowlist_storage
    echo "$v" > "$SSH_PORT_OVERRIDE_FILE"
    chmod 600 "$SSH_PORT_OVERRIDE_FILE" || true
}

clear_ssh_port_override() {
    rm -f "$SSH_PORT_OVERRIDE_FILE" >/dev/null 2>&1 || true
}

# 端口探测（返回“单个端口”）
get_effective_ssh_port() {
    # 0) 覆盖优先（仅用于白名单）
    local ov=""
    ov="$(read_ssh_port_override 2>/dev/null || true)"
    if [[ -n "$ov" ]]; then
        echo "$ov"
        return 0
    fi

    # 1) 当前会话端口（最可靠）
    local sp=""
    sp="$(get_current_session_ssh_port 2>/dev/null || true)"
    if [[ -n "$sp" ]] && [[ "$sp" =~ ^[0-9]+$ ]] && (( sp >= 1 && sp <= 65535 )); then
        echo "$sp"
        return 0
    fi

    # 2) sshd -T（含 include/drop-in 的生效配置）
    if command -v sshd >/dev/null 2>&1; then
        local ports
        ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//' || true)"
        if [[ -n "$ports" ]]; then
            echo "$ports" | awk '{print $1}'
            return 0
        fi
    fi

    # 3) ss/netstat 监听端口
    if command -v ss >/dev/null 2>&1; then
        local p2
        p2="$(ss -lntp 2>/dev/null | awk '
            /sshd/ && $1 ~ /^LISTEN/ {
                n=split($4,a,":");
                port=a[n];
                if (port ~ /^[0-9]+$/) print port
            }' | sort -n | uniq | head -n1 || true)"
        if [[ -n "$p2" ]]; then echo "$p2"; return 0; fi
    elif command -v netstat >/dev/null 2>&1; then
        local p3
        p3="$(netstat -lntp 2>/dev/null | awk '
            /sshd/ && $1 ~ /^tcp/ {
                n=split($4,a,":");
                port=a[n];
                if (port ~ /^[0-9]+$/) print port
            }' | sort -n | uniq | head -n1 || true)"
        if [[ -n "$p3" ]]; then echo "$p3"; return 0; fi
    fi

    # 4) fail2ban jail.local
    local p4=""
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        p4="$(get_sshd_value port)"
        if [[ -n "$p4" ]] && [[ "$p4" =~ ^[0-9]+$ ]] && (( p4>=1 && p4<=65535 )); then
            echo "$p4"; return 0
        fi
    fi

    # 5) sshd_config（保底）
    local p5=""
    if [[ -f /etc/ssh/sshd_config ]]; then
        p5="$(awk '
            /^[[:space:]]*#/ {next}
            tolower($1)=="port" {print $2; exit}
        ' /etc/ssh/sshd_config 2>/dev/null || true)"
        if [[ -n "$p5" ]] && [[ "$p5" =~ ^[0-9]+$ ]] && (( p5>=1 && p5<=65535 )); then
            echo "$p5"; return 0
        fi
    fi

    echo "22"
    return 0
}

show_detected_ports_hint() {
    local sessionp=""
    sessionp="$(get_current_session_ssh_port 2>/dev/null || true)"

    local tt=""
    if command -v sshd >/dev/null 2>&1; then
        tt="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | xargs 2>/dev/null || true)"
    fi

    local ssports=""
    if command -v ss >/dev/null 2>&1; then
        ssports="$(ss -lntp 2>/dev/null | awk '
            /sshd/ && $1 ~ /^LISTEN/ {
                n=split($4,a,":"); port=a[n];
                if (port ~ /^[0-9]+$/) print port
            }' | sort -n | uniq | xargs 2>/dev/null || true)"
    fi

    echo "端口探测参考："
    [[ -n "$sessionp" ]] && echo "  - 当前会话端口(最优先): $sessionp"
    [[ -n "$tt" ]] && echo "  - sshd -T 生效端口: $tt"
    [[ -n "$ssports" ]] && echo "  - sshd 监听端口(ss): $ssports"
}

#-----------------------------
# 运行时规则下发（立即应用）
#-----------------------------
apply_allowlist_rules_iptables() {
    local port="$1"
    ensure_allowlist_storage

    if ! command -v iptables >/dev/null 2>&1; then
        echo "❌ 未找到 iptables 命令，无法应用白名单规则。"
        return 1
    fi

    iptables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    iptables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    iptables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true

    iptables -N "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    iptables -A "$IPTABLES_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" == *:* ]] && continue
        iptables -A "$IPTABLES_CHAIN" -s "$ip" -p tcp --dport "$port" -j ACCEPT
    done < "$ALLOWLIST_FILE"

    iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j DROP
    iptables -I INPUT 1 -p tcp --dport "$port" -j "$IPTABLES_CHAIN"

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true

        ip6tables -N "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -A "$IPTABLES_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            [[ "$ip" != *:* ]] && continue
            ip6tables -A "$IPTABLES_CHAIN" -s "$ip" -p tcp --dport "$port" -j ACCEPT
        done < "$ALLOWLIST_FILE"

        ip6tables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j DROP
        ip6tables -I INPUT 1 -p tcp --dport "$port" -j "$IPTABLES_CHAIN"
    fi

    echo "✅ [iptables] 已应用运行时 SSH 白名单规则（端口 $port）。"
    return 0
}

remove_allowlist_rules_iptables() {
    local port="$1"
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        iptables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        iptables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    fi
    echo "✅ [iptables] 已移除运行时 SSH 白名单限制（端口 $port）。"
    return 0
}

apply_allowlist_rules_nftables() {
    local port="$1"
    ensure_allowlist_storage

    if ! command -v nft >/dev/null 2>&1; then
        echo "❌ 未找到 nft 命令，无法应用白名单规则。"
        return 1
    fi

    nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    nft add table "$NFT_FAMILY" "$NFT_TABLE"
    nft add chain "$NFT_FAMILY" "$NFT_TABLE" input "{ type filter hook input priority -50; policy accept; }"
    nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ct state established,related accept

    local v4_set="" v6_set=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == *:* ]]; then v6_set+="${ip},"; else v4_set+="${ip},"; fi
    done < "$ALLOWLIST_FILE"

    if [[ -n "$v4_set" ]]; then
        v4_set="${v4_set%,}"
        nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ip saddr "{ $v4_set }" tcp dport "$port" accept
    fi
    if [[ -n "$v6_set" ]]; then
        v6_set="${v6_set%,}"
        nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ip6 saddr "{ $v6_set }" tcp dport "$port" accept
    fi

    nft add rule "$NFT_FAMILY" "$NFT_TABLE" input tcp dport "$port" drop
    echo "✅ [nftables] 已应用运行时 SSH 白名单规则（端口 $port）。"
    return 0
}

remove_allowlist_rules_nftables() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    echo "✅ [nftables] 已移除运行时 SSH 白名单限制。"
    return 0
}

firewalld_supports_ipset() {
    firewall-cmd --permanent --get-ipsets >/dev/null 2>&1
}

apply_allowlist_rules_firewalld() {
    local port="$1"
    ensure_allowlist_storage

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "❌ 未找到 firewall-cmd，无法应用白名单规则。"
        return 1
    fi
    if ! firewalld_supports_ipset; then
        echo "❌ firewalld 未就绪或不支持 ipset（或未运行）。"
        echo "   建议：systemctl status firewalld"
        return 1
    fi

    firewall-cmd --permanent --delete-ipset="$FIREWALLD_IPSET" >/dev/null 2>&1 || true
    firewall-cmd --permanent --new-ipset="$FIREWALLD_IPSET" --type=hash:ip >/dev/null 2>&1 || true

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        firewall-cmd --permanent --ipset="$FIREWALLD_IPSET" --add-entry="$ip" >/dev/null 2>&1 || true
    done < "$ALLOWLIST_FILE"

    local rule_allow="rule source ipset=\"$FIREWALLD_IPSET\" port port=\"$port\" protocol=\"tcp\" accept"
    local rule_drop="rule port port=\"$port\" protocol=\"tcp\" drop"

    firewall-cmd --permanent --remove-rich-rule="$rule_allow" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-rich-rule="$rule_drop" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-rich-rule="$rule_allow"
    firewall-cmd --permanent --add-rich-rule="$rule_drop"

    firewall-cmd --reload >/dev/null 2>&1 || firewall-cmd --complete-reload >/dev/null 2>&1 || true
    echo "✅ [firewalld] 已应用（且已写入 permanent）SSH 白名单规则（端口 $port）。"
    return 0
}

remove_allowlist_rules_firewalld() {
    local port="$1"
    if ! command -v firewall-cmd >/dev/null 2>&1; then return 0; fi

    local rule_allow="rule source ipset=\"$FIREWALLD_IPSET\" port port=\"$port\" protocol=\"tcp\" accept"
    local rule_drop="rule port port=\"$port\" protocol=\"tcp\" drop"

    firewall-cmd --permanent --remove-rich-rule="$rule_allow" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-rich-rule="$rule_drop" >/dev/null 2>&1 || true
    firewall-cmd --permanent --delete-ipset="$FIREWALLD_IPSET" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || firewall-cmd --complete-reload >/dev/null 2>&1 || true
    echo "✅ [firewalld] 已移除 SSH 白名单限制（端口 $port）。"
    return 0
}

apply_allowlist_rules() {
    local port="$1"
    detect_firewall
    case "$FIREWALL" in
        firewalld) apply_allowlist_rules_firewalld "$port" ;;
        nftables)  apply_allowlist_rules_nftables "$port" ;;
        *)         apply_allowlist_rules_iptables "$port" ;;
    esac
}

remove_allowlist_rules() {
    local port="$1"
    detect_firewall
    case "$FIREWALL" in
        firewalld) remove_allowlist_rules_firewalld "$port" ;;
        nftables)  remove_allowlist_rules_nftables ;;
        *)         remove_allowlist_rules_iptables "$port" ;;
    esac
}

enable_allowlist_flag() { ensure_allowlist_storage; : > "$ALLOWLIST_ENABLED_FLAG"; }
disable_allowlist_flag() { rm -f "$ALLOWLIST_ENABLED_FLAG" >/dev/null 2>&1 || true; }

#-----------------------------
# 方案B：systemd 兜底（关键：只要启用白名单，就始终启用B）
#-----------------------------
ensure_systemd_fallback_unit() {
    have_systemd || return 1

    # 确保 fb5 命令存在（systemd ExecStart 依赖它）
    if [[ ! -x "$INSTALL_CMD_PATH" ]]; then
        install_fb5_now >/dev/null 2>&1 || true
    fi
    [[ -x "$INSTALL_CMD_PATH" ]] || return 1

    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=FB5 SSH Allowlist Enforcer (Boot Re-Apply)
After=network-online.target
Wants=network-online.target
After=firewalld.service nftables.service
Wants=firewalld.service nftables.service

[Service]
Type=oneshot
ExecStart=${INSTALL_CMD_PATH} --apply-allowlist
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

enable_systemd_fallback() {
    have_systemd || return 1
    ensure_systemd_fallback_unit || return 1
    systemctl enable --now fb5-ssh-allowlist >/dev/null 2>&1 || return 1
    return 0
}

disable_systemd_fallback() {
    have_systemd || return 0
    systemctl disable --now fb5-ssh-allowlist >/dev/null 2>&1 || true
    return 0
}

#-----------------------------
# 方案A：系统原生持久化（尽力而为）
#-----------------------------
build_nft_persist_file() {
    local port="$1"
    ensure_allowlist_storage
    mkdir -p "$NFT_PERSIST_DIR"

    local v4_items="" v6_items=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == *:* ]]; then
            v6_items+="${ip},"
        else
            v4_items+="${ip},"
        fi
    done < "$ALLOWLIST_FILE"
    v4_items="${v4_items%,}"
    v6_items="${v6_items%,}"

    {
        echo "# Auto-generated by fb5 on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "flush table ${NFT_FAMILY} ${NFT_TABLE}"
        echo "table ${NFT_FAMILY} ${NFT_TABLE} {"
        echo "  chain input {"
        echo "    type filter hook input priority -50; policy accept;"
        echo "    ct state established,related accept"
        if [[ -n "$v4_items" ]]; then
            echo "    ip saddr { ${v4_items} } tcp dport ${port} accept"
        fi
        if [[ -n "$v6_items" ]]; then
            echo "    ip6 saddr { ${v6_items} } tcp dport ${port} accept"
        fi
        echo "    tcp dport ${port} drop"
        echo "  }"
        echo "}"
    } > "$NFT_PERSIST_FILE"
}

ensure_nft_main_conf_include() {
    if [[ ! -f "$NFT_MAIN_CONF" ]]; then
        cat > "$NFT_MAIN_CONF" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
EOF
        return 0
    fi

    if ! grep -qE 'include\s+"?/etc/nftables\.d/\*\.nft"?|include\s+".*/nftables\.d/\*\.nft"' "$NFT_MAIN_CONF"; then
        echo 'include "/etc/nftables.d/*.nft"' >> "$NFT_MAIN_CONF"
    fi
    return 0
}

persist_allowlist_A_firewalld() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then return 1; fi
    if have_systemd; then
        systemctl is-active --quiet firewalld 2>/dev/null || return 1
    fi
    return 0
}

persist_allowlist_A_nftables() {
    local port="$1"
    command -v nft >/dev/null 2>&1 || return 1

    build_nft_persist_file "$port"
    ensure_nft_main_conf_include || return 1

    if have_systemd; then
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl restart nftables >/dev/null 2>&1 || nft -f "$NFT_MAIN_CONF" >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    return 0
}

persist_allowlist_A_iptables_debian() {
    command -v iptables-save >/dev/null 2>&1 || return 1

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        fix_pkg_mgr || true
        install_pkgs iptables-persistent netfilter-persistent >/dev/null 2>&1 || install_pkgs iptables-persistent >/dev/null 2>&1 || true
    fi

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || return 1
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi

    if have_systemd && command -v netfilter-persistent >/dev/null 2>&1; then
        systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
        netfilter-persistent reload >/dev/null 2>&1 || true
        return 0
    fi

    return 1
}

persist_allowlist_A_iptables_rhel() {
    command -v iptables-save >/dev/null 2>&1 || return 1
    fix_pkg_mgr || true
    install_pkgs iptables-services >/dev/null 2>&1 || true

    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || return 1
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
    fi

    if have_systemd; then
        systemctl enable --now iptables >/dev/null 2>&1 || return 1
        if systemctl list-unit-files | grep -q '^ip6tables\.service'; then
            systemctl enable --now ip6tables >/dev/null 2>&1 || true
        fi
        return 0
    fi

    return 1
}

persist_allowlist_A_iptables() {
    detect_os
    case "$OS" in
        ubuntu|debian|debianlike) persist_allowlist_A_iptables_debian ;;
        centos|rhel|rocky|almalinux|fedora|rhellike) persist_allowlist_A_iptables_rhel ;;
        *) persist_allowlist_A_iptables_debian || persist_allowlist_A_iptables_rhel ;;
    esac
}

persist_allowlist_A() {
    local port="$1"
    detect_firewall
    case "$FIREWALL" in
        firewalld) persist_allowlist_A_firewalld ;;
        nftables)  persist_allowlist_A_nftables "$port" ;;
        *)         persist_allowlist_A_iptables ;;
    esac
}

remove_persist_A_nftables() {
    rm -f "$NFT_PERSIST_FILE" >/dev/null 2>&1 || true
    if have_systemd; then
        systemctl restart nftables >/dev/null 2>&1 || true
    fi
    return 0
}

remove_persist_A_iptables_debian() {
    rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 >/dev/null 2>&1 || true
    if have_systemd; then
        systemctl restart netfilter-persistent >/dev/null 2>&1 || true
    fi
    return 0
}

remove_persist_A_iptables_rhel() {
    rm -f /etc/sysconfig/iptables /etc/sysconfig/ip6tables >/dev/null 2>&1 || true
    if have_systemd; then
        systemctl restart iptables >/dev/null 2>&1 || true
        systemctl restart ip6tables >/dev/null 2>&1 || true
    fi
    return 0
}

remove_persist_A() {
    detect_firewall
    detect_os
    case "$FIREWALL" in
        firewalld) return 0 ;;
        nftables)  remove_persist_A_nftables ;;
        *)
            case "$OS" in
                ubuntu|debian|debianlike) remove_persist_A_iptables_debian ;;
                centos|rhel|rocky|almalinux|fedora|rhellike) remove_persist_A_iptables_rhel ;;
                *) remove_persist_A_iptables_debian || true; remove_persist_A_iptables_rhel || true ;;
            esac
            ;;
    esac
    return 0
}

#-----------------------------
# 核心：立即应用（运行时 + A尽力 + B强制启用保证重启恢复）
#-----------------------------
apply_allowlist_immediately_or_disable_if_empty() {
    local port="$1"

    sync_current_ssh_ip_to_allowlist

    if [[ ! -s "$ALLOWLIST_FILE" ]]; then
        echo "⚠ 白名单已为空。为避免阻断所有 SSH 新连接，将自动关闭白名单限制。"
        remove_allowlist_rules "$port" || true
        remove_persist_A || true
        disable_systemd_fallback || true
        disable_allowlist_flag
        return 0
    fi

    if ! apply_allowlist_rules "$port"; then
        echo "❌ 运行时规则应用失败（请检查防火墙状态/权限/冲突规则）。"
        return 1
    fi

    # 标记启用
    enable_allowlist_flag

    # 方案A：尽力写入（成功与否都不影响最终“重启可恢复”）
    if persist_allowlist_A "$port"; then
        echo "✅ 持久化(A)已写入（系统原生机制）。"
    else
        echo "⚠ 持久化(A)未确认成功（不影响最终效果，将由兜底(B)保证重启恢复）。"
    fi

    # 关键：只要白名单启用，就【始终】启用 systemd 兜底(B)，确保每次重启重放规则
    if have_systemd; then
        if enable_systemd_fallback; then
            echo "✅ 兜底(B)已启用：重启后会自动重新下发白名单规则。"
        else
            echo "❌ 兜底(B)启用失败（可能无 systemd 或 /usr/local/bin/fb5 不可用）。"
            echo "   该情况下只能依赖(A)；若(A)也不稳定，重启后可能失效。"
            return 1
        fi
    else
        echo "⚠ 系统无 systemd，无法启用兜底(B)。将仅依赖(A)持久化。"
    fi

    return 0
}

confirm_or_override_port_once() {
    ensure_allowlist_storage

    local existing=""
    existing="$(read_ssh_port_override 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        return 0
    fi

    echo ""
    show_detected_ports_hint
    local auto_port
    auto_port="$(get_effective_ssh_port)"
    echo ""
    echo "白名单将使用 SSH 端口：$auto_port"
    echo "  - 回车：确认使用自动探测端口"
    echo "  - 输入端口：覆盖（会持久化保存）"
    echo "  - 输入 0：保持自动（不保存覆盖）"
    local inp=""
    read -rp "请输入（回车/端口/0）: " inp

    if [[ -z "$inp" || "$inp" == "0" ]]; then
        return 0
    fi

    if [[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= 65535 )); then
        write_ssh_port_override "$inp"
        echo "✅ 已设置白名单端口覆盖：$inp"
        return 0
    fi

    echo "⚠ 输入无效，已保持自动探测。"
    return 0
}

#-----------------------------
# 白名单菜单
#-----------------------------
ssh_allowlist_menu() {
    detect_firewall
    ensure_allowlist_storage
    sync_current_ssh_ip_to_allowlist

    confirm_or_override_port_once

    local port
    port="$(get_effective_ssh_port)"

    while true; do
        clear
        echo "==============================================="
        echo " SSH 连接白名单（只允许白名单 IP 连接 SSH）"
        echo " 防火墙类型: $FIREWALL"
        echo " SSH 端口(当前生效): $port"
        echo " 白名单文件: $ALLOWLIST_FILE"
        echo " 端口覆盖文件: $SSH_PORT_OVERRIDE_FILE（存在则覆盖）"
        echo "==============================================="
        echo " 1) 查看当前白名单（会自动包含当前 SSH 来源 IP）"
        echo " 2) 追加添加 IP（立刻生效；并自动加入当前 SSH 来源 IP）"
        echo " 3) 删除白名单 IP（立刻生效；若删空将自动关闭限制）"
        echo " 4) 关闭白名单限制（移除规则；保留列表文件）"
        echo " 5) 修改/清除白名单端口覆盖（立即应用现有规则到新端口）"
        echo " 0) 返回主菜单"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-5]: " C

        case "$C" in
            1)
                sync_current_ssh_ip_to_allowlist
                allowlist_show
                echo ""
                pause
                ;;
            2)
                local ip=""
                read -rp "请输入要允许 SSH 连接的 IP（如 1.1.1.1；回车取消）: " ip
                if [[ -z "$ip" ]]; then echo "已取消。"; pause; continue; fi
                if ! is_valid_ip_or_cidr "$ip"; then echo "⚠ IP 格式不正确：$ip"; pause; continue; fi

                allowlist_add_ip "$ip" || { echo "❌ 加入失败：$ip"; pause; continue; }
                sync_current_ssh_ip_to_allowlist

                local cur=""; cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
                if [[ -n "$cur" ]]; then
                    echo "🧾 当前 SSH 来源 IP：$cur（已确保在白名单中）"
                else
                    echo "ℹ️ 未检测到 SSH 来源 IP（可能控制台执行），已跳过自动加入。"
                fi

                echo ""
                echo "⚠ 将立即应用白名单规则：除白名单 IP 外，其他 IP 将无法建立新的 SSH 连接。"
                read -rp "确认继续吗？[y/N]: " ok
                case "$ok" in
                    y|Y) ;;
                    *) echo "已取消应用（但白名单列表已更新）。"; pause; continue ;;
                esac

                port="$(get_effective_ssh_port)"
                apply_allowlist_immediately_or_disable_if_empty "$port" || true
                echo ""
                pause
                ;;
            3)
                sync_current_ssh_ip_to_allowlist
                allowlist_show
                echo ""
                local dip=""
                read -rp "请输入要删除的 IP（需与列表完全一致；回车取消）: " dip
                if [[ -z "$dip" ]]; then echo "已取消。"; pause; continue; fi

                local cur2=""; cur2="$(get_current_ssh_client_ip 2>/dev/null || true)"
                if [[ -n "$cur2" && "$dip" == "$cur2" ]]; then
                    echo "⚠ 你正在删除当前 SSH 来源 IP：$cur2"
                    echo "   这可能导致你断开后无法重新连接。"
                    read -rp "仍要继续删除并立即生效吗？[y/N]: " risk
                    case "$risk" in
                        y|Y) ;;
                        *) echo "已取消。"; pause; continue ;;
                    esac
                fi

                allowlist_del_ip "$dip" || { echo "⚠ 白名单中不存在：$dip"; pause; continue; }

                port="$(get_effective_ssh_port)"
                apply_allowlist_immediately_or_disable_if_empty "$port" || true
                echo ""
                pause
                ;;
            4)
                echo "⚠ 即将移除 SSH 白名单限制（不删除白名单列表文件）。"
                read -rp "确认继续吗？[y/N]: " ok2
                case "$ok2" in
                    y|Y) ;;
                    *) echo "已取消。"; pause; continue ;;
                esac

                port="$(get_effective_ssh_port)"
                remove_allowlist_rules "$port" || true
                remove_persist_A || true
                disable_systemd_fallback || true
                disable_allowlist_flag

                echo "✅ 已关闭白名单限制（运行时/持久化/兜底均已处理）。"
                echo ""
                pause
                ;;
            5)
                echo ""
                echo "当前端口覆盖：$(read_ssh_port_override 2>/dev/null || echo '无（自动）')"
                echo "请输入新的覆盖端口（1-65535），或输入 0 清除覆盖并恢复自动。"
                local np=""
                read -rp "请输入: " np
                if [[ -z "$np" ]]; then
                    echo "已取消。"
                    pause
                    continue
                fi

                local old_port
                old_port="$(get_effective_ssh_port)"

                if [[ "$np" == "0" ]]; then
                    clear_ssh_port_override
                    echo "✅ 已清除端口覆盖，恢复自动探测。"
                elif [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1 && np <= 65535 )); then
                    write_ssh_port_override "$np"
                    echo "✅ 已设置端口覆盖：$np"
                else
                    echo "⚠ 输入无效。"
                    pause
                    continue
                fi

                local new_port
                new_port="$(get_effective_ssh_port)"

                if [[ -f "$ALLOWLIST_ENABLED_FLAG" ]]; then
                    echo "🔁 检测到白名单已启用，将从端口 $old_port 迁移到端口 $new_port（立即生效）。"
                    remove_allowlist_rules "$old_port" || true
                    apply_allowlist_immediately_or_disable_if_empty "$new_port" || true
                else
                    echo "ℹ️ 白名单当前未启用，仅更新端口设置。"
                fi

                port="$new_port"
                echo ""
                pause
                ;;
            0) return ;;
            *) echo "❌ 无效选项。"; pause ;;
        esac
    done
}

#-----------------------------
# 1. 安装 / 配置 SSH 防爆破
#-----------------------------
install_or_config_ssh() {
    detect_os
    detect_firewall
    ensure_curl

    echo "🧩 系统类型: $OS"
    echo "🛡 防火墙: $FIREWALL"
    echo "📦 包管理器: $(detect_pkg_mgr)"
    echo ""

    echo "📦 检查并尽力修复包管理器状态（不中断主流程）..."
    fix_pkg_mgr || true

    local SSH_PORT=""
    SSH_PORT="$(prompt_ssh_port)"

    echo "📦 检查 Fail2ban 是否已安装..."
    if command -v fail2ban-client &>/dev/null; then
        echo "✅ Fail2ban 已安装，跳过安装步骤。"
    else
        echo "📦 安装 Fail2ban..."
        local PM; PM="$(detect_pkg_mgr)"
        if [[ "$PM" == "apt" ]]; then
            install_pkgs fail2ban
        elif [[ "$PM" == "dnf" || "$PM" == "yum" ]]; then
            install_pkgs epel-release >/dev/null 2>&1 || true
            install_pkgs fail2ban fail2ban-firewalld || install_pkgs fail2ban
        else
            echo "❌ 未识别包管理器，无法自动安装 Fail2ban。"
            pause; return
        fi
    fi

    echo "📁 确保 /etc/fail2ban 目录存在..."
    mkdir -p /etc/fail2ban

    if [[ ! -f "$JAIL" ]]; then
        echo "📄 创建新的 jail.local..."
        local MYIP="127.0.0.1"
        local TMPIP=""
        TMPIP=$(curl -s --max-time 5 https://api.ipify.org || true)
        [[ -n "$TMPIP" ]] && MYIP="$TMPIP"

        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime  = 12h
findtime = 6h
maxretry = 3
EOF
    fi

    local CUR_SSH_IP=""
    CUR_SSH_IP="$(get_current_ssh_client_ip 2>/dev/null || true)"
    if [[ -n "$CUR_SSH_IP" ]]; then
        echo "🧾 检测到当前 SSH 来源 IP：$CUR_SSH_IP"
        add_ip_to_ignoreip "$CUR_SSH_IP" || true

        ensure_allowlist_storage
        allowlist_add_ip "$CUR_SSH_IP" >/dev/null 2>&1 || true
    else
        echo "ℹ️ 未检测到 SSH 环境变量（可能是控制台执行），跳过自动白名单。"
    fi

    local ACTION; ACTION="$(get_action_for_firewall)"
    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME
    CUR_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="3"
    CUR_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="21600"
    CUR_BANTIME="$(get_sshd_value bantime)";  [[ -z "$CUR_BANTIME"  ]] && CUR_BANTIME="12h"
    local LOGPATH; LOGPATH="$(pick_ssh_logpath)"

    echo "🛡 写入/更新 SSH 防爆破配置到 jail.local（端口: $SSH_PORT）..."
    rewrite_or_append_sshd_block "$SSH_PORT" "$ACTION" "$LOGPATH" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    echo "🔄 重启 Fail2ban..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 是否有语法错误。"
        pause; return
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true

    echo ""
    echo "✅ SSH 防爆破配置完成！"
    echo ""
    echo "🔧 正在安装快捷命令 fb5..."
    install_fb5_now || true

    echo ""
    print_status_summary
    echo "📌 查看详细状态：fail2ban-client status sshd"
    echo "📌 立即可用命令：fb5"
    echo ""
    pause
}

#-----------------------------
# 2. 快捷修改 SSH 防爆破参数
#-----------------------------
modify_ssh_params() {
    if [[ ! -f "$JAIL" ]]; then
        echo "⚠ 未检测到 $JAIL，请先执行『1) 安装/配置 SSH 防爆破』"
        pause; return
    fi
    if ! grep -q "^\[sshd\]" "$JAIL"; then
        echo "⚠ jail.local 中没有 [sshd] 段，请先通过菜单 1 生成。"
        pause; return
    fi

    local CURRENT_MAXRETRY CURRENT_BANTIME CURRENT_FINDTIME CURRENT_PORT
    CURRENT_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CURRENT_MAXRETRY" ]] && CURRENT_MAXRETRY="3"
    CURRENT_BANTIME="$(get_sshd_value bantime)";  [[ -z "$CURRENT_BANTIME"  ]] && CURRENT_BANTIME="12h"
    CURRENT_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CURRENT_FINDTIME" ]] && CURRENT_FINDTIME="21600"
    CURRENT_PORT="$(get_sshd_value port)"; [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="22"

    echo "================ 快捷修改 SSH 防爆破参数 ================"
    echo "当前 SSH 配置："
    echo "  port（SSH 端口）       : $CURRENT_PORT"
    echo "  maxretry（失败次数）   : $CURRENT_MAXRETRY"
    echo "  bantime（封禁时长）    : $CURRENT_BANTIME"
    echo "  findtime（检测周期 秒）: $CURRENT_FINDTIME"
    echo "---------------------------------------------------------"
    echo "留空则表示不修改该项。"
    echo "bantime 支持格式：600（秒）、12h、1d 等 Fail2ban 支持的时长格式。"
    echo "findtime 用秒数，比如 21600 表示 6 小时。"
    echo "========================================================="
    echo ""

    read -rp "请输入新的 maxretry（失败次数，例：3，留空不改）： " NEW_MAXRETRY
    read -rp "请输入新的 bantime（封禁时长，例：12h 或 3600，留空不改）： " NEW_BANTIME
    read -rp "请输入新的 findtime（检测周期秒数，例：21600，留空不改）： " NEW_FINDTIME

    if [[ -z "$NEW_MAXRETRY" && -z "$NEW_BANTIME" && -z "$NEW_FINDTIME" ]]; then
        echo "ℹ️ 未输入任何修改，保持原样。"
        pause; return
    fi

    local FINAL_MAXRETRY FINAL_BANTIME FINAL_FINDTIME
    FINAL_MAXRETRY="$CURRENT_MAXRETRY"
    FINAL_BANTIME="$CURRENT_BANTIME"
    FINAL_FINDTIME="$CURRENT_FINDTIME"

    if [[ -n "$NEW_MAXRETRY" ]]; then
        if ! [[ "$NEW_MAXRETRY" =~ ^[0-9]+$ ]]; then
            echo "⚠ maxretry 必须是整数，已忽略该项修改。"
        else
            FINAL_MAXRETRY="$NEW_MAXRETRY"
            echo "✅ maxretry 将修改为：$FINAL_MAXRETRY"
        fi
    fi

    if [[ -n "$NEW_BANTIME" ]]; then
        FINAL_BANTIME="$NEW_BANTIME"
        echo "✅ bantime 将修改为：$FINAL_BANTIME"
    fi

    if [[ -n "$NEW_FINDTIME" ]]; then
        if ! [[ "$NEW_FINDTIME" =~ ^[0-9]+$ ]]; then
            echo "⚠ findtime 必须是整数秒数，已忽略该项修改。"
        else
            FINAL_FINDTIME="$NEW_FINDTIME"
            echo "✅ findtime 将修改为：$FINAL_FINDTIME 秒"
        fi
    fi

    local ACTION LOGPATH
    ACTION="$(get_sshd_value action)"
    [[ -z "$ACTION" ]] && ACTION="$(get_action_for_firewall)"
    LOGPATH="$(get_sshd_value logpath)"
    [[ -z "$LOGPATH" ]] && LOGPATH="$(pick_ssh_logpath)"

    echo "🛠 更新 [sshd] 段..."
    rewrite_or_append_sshd_block "$CURRENT_PORT" "$ACTION" "$LOGPATH" "$FINAL_MAXRETRY" "$FINAL_FINDTIME" "$FINAL_BANTIME"

    echo "🔄 重启 Fail2ban 以应用新参数..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 是否有语法错误。"
        pause; return
    fi

    echo ""
    echo "✅ 修改已生效！"
    print_status_summary
    echo ""
    pause
}

#-----------------------------
# 3. 卸载本脚本相关配置
#-----------------------------
uninstall_all() {
    echo "⚠ 此操作将删除："
    echo "   - /etc/fail2ban/jail.local（若存在，会直接删除整个文件）"
    echo "   - 白名单兜底服务(B)：fb5-ssh-allowlist（若存在）"
    echo "   - 白名单端口覆盖文件：$SSH_PORT_OVERRIDE_FILE（若存在）"
    echo ""
    read -rp "是否同时删除快捷命令 $INSTALL_CMD_PATH ? [y/N]: " RM_CMD
    case "$RM_CMD" in
        y|Y) rm -f "$INSTALL_CMD_PATH"; echo "✅ 已删除快捷命令：$INSTALL_CMD_PATH" ;;
        *)   echo "已保留快捷命令（如存在）。" ;;
    esac

    read -rp "确认继续删除上述 Fail2ban 配置吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *)   echo "已取消卸载配置。"; pause; return ;;
    esac

    systemctl stop fail2ban 2>/dev/null || true
    rm -f /etc/fail2ban/jail.local
    echo "✅ Fail2ban 自定义配置文件已删除。"

    local port; port="$(get_effective_ssh_port)"
    remove_allowlist_rules "$port" || true
    remove_persist_A || true
    disable_systemd_fallback || true
    rm -f "$SYSTEMD_UNIT" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    clear_ssh_port_override || true
    disable_allowlist_flag

    read -rp "是否同时卸载 fail2ban 软件包？[y/N]: " CONFIRM2
    case "$CONFIRM2" in
        y|Y)
            local PM; PM="$(detect_pkg_mgr)"
            if [[ "$PM" == "apt" ]]; then
                apt-get purge -y fail2ban || true
            elif [[ "$PM" == "dnf" ]]; then
                dnf -y remove fail2ban || true
            elif [[ "$PM" == "yum" ]]; then
                yum -y remove fail2ban || true
            else
                echo "⚠ 未识别包管理器，跳过卸载软件包。"
            fi
            systemctl disable fail2ban 2>/dev/null || true
            echo "✅ fail2ban 软件包已卸载。"
            ;;
        *)  echo "已保留 fail2ban 软件包（但已无自定义配置）。" ;;
    esac

    pause
}

#-----------------------------
# 4. 从远程更新 fb5（仅更新功能）
#-----------------------------
update_fb5_from_remote() {
    ensure_curl
    echo "================ 远程更新 fb5 脚本 ================"
    echo "将从远程地址："
    echo "  $REMOTE_URL"
    echo "下载并覆盖到："
    echo "  $INSTALL_CMD_PATH"
    echo "===================================================="
    echo ""
    read -rp "确认进行远程更新吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *)   echo "已取消。"; pause; return ;;
    esac

    mkdir -p "$(dirname "$INSTALL_CMD_PATH")"
    if ! curl -fsSL "$REMOTE_URL" -o "$INSTALL_CMD_PATH"; then
        echo "❌ 远程更新失败，请检查网络或仓库地址是否可访问。"
        pause; return
    fi

    chmod +x "$INSTALL_CMD_PATH"
    echo "✅ 更新完成：$INSTALL_CMD_PATH"
    echo "👉 现在可直接运行：fb5"
    echo ""
    pause
}

#-----------------------------
# 命令行模式：供 systemd 兜底调用（不可交互）
#-----------------------------
cli_apply_allowlist() {
    detect_firewall
    ensure_allowlist_storage
    sync_current_ssh_ip_to_allowlist

    if [[ ! -f "$ALLOWLIST_ENABLED_FLAG" ]]; then
        exit 0
    fi

    local port
    port="$(get_effective_ssh_port)"

    apply_allowlist_immediately_or_disable_if_empty "$port" >/dev/null 2>&1 || exit 0
    exit 0
}

#-----------------------------
# 主菜单
#-----------------------------
main_menu() {
    while true; do
        clear
        echo "==============================================="
        echo " Fail2ban SSH 防爆破 管理脚本"
        echo " Author: DadaGi 大大怪"
        echo "==============================================="
        print_status_summary
        echo " 1) 安装 / 配置 SSH 防爆破（自动白名单当前 SSH IP）"
        echo " 2) 快捷修改 SSH 防爆破参数（失败次数 / 封禁时长 / 检测周期）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 4) 远程更新 fb5 脚本（仅更新功能）"
        echo " 5) 查看 sshd 封禁 IP 列表"
        echo " 6) 解禁指定 IP（sshd）"
        echo " 7) SSH 连接白名单（新增/删除后立即生效，重启后也会恢复）"
        echo " 0) 退出"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-7]: " CHOICE
        case "$CHOICE" in
            1) install_or_config_ssh ;;
            2) modify_ssh_params ;;
            3) uninstall_all ;;
            4) update_fb5_from_remote ;;
            5) view_banned_ips ;;
            6) unban_ip ;;
            7) ssh_allowlist_menu ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "❌ 无效选项。"; pause ;;
        esac
    done
}

#-----------------------------
# 入口：systemd 兜底调用
#-----------------------------
if [[ "${1:-}" == "--apply-allowlist" ]]; then
    ensure_root
    cli_apply_allowlist
fi

ensure_root
main_menu
