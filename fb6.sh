#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector 菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 功能：
#   1) 安装 / 配置 Fail2ban 仅用于 SSH 防爆破
#      - 安装时输入 SSH 端口（回车默认 22）
#      - 自动把当前 SSH 来源 IP 加入 ignoreip 白名单（避免误封自己）
#      - 安装完成后自动安装 fb5 命令：/usr/local/bin/fb5
#   2) 快捷修改 SSH 防爆破参数（maxretry / bantime / findtime）
#   3) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#   4) 从远程更新 fb5 脚本（仅更新功能：下载覆盖并赋权）
#   5) 查看当前封禁 IP 列表（sshd jail）
#   6) 解禁指定 IP（sshd jail）
#   7) SSH 连接白名单（只允许白名单 IP 连接 SSH；支持追加/删除/关闭）
#      - 新增/删除后立即生效（无需再点“应用”）
#      - 新增时自动把当前 SSH 来源 IP 一并加入白名单，避免误锁
#
# 默认策略（首次安装 / 无 [sshd] 参数时）：
#   - maxretry = 3
#   - findtime = 21600（6小时）
#   - bantime  = 12h
#
# 说明：
#   - Fail2ban 只对 [sshd] jail 动手
#   - SSH 白名单功能会改动系统防火墙规则（iptables/nftables/firewalld）
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

# SSH 白名单（仅允许这些 IP 连接 SSH）
ALLOWLIST_DIR="/etc/fb5"
ALLOWLIST_FILE="${ALLOWLIST_DIR}/ssh_allowlist.txt"
ALLOWLIST_ENABLED_FLAG="${ALLOWLIST_DIR}/ssh_allowlist_enabled"  # 用于标识白名单限制已启用
IPTABLES_CHAIN="FB5_SSH_ALLOW"
NFT_TABLE="fb5"
NFT_FAMILY="inet"
FIREWALLD_IPSET="fb5-ssh-allow"

#-----------------------------
# 工具函数
#-----------------------------
pause() {
    read -rp "按 Enter 返回菜单..." _
}

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

#-----------------------------
# 包管理器：探测 / 修复 / 安装（更稳健）
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
    echo "✅ [APT] 修复流程已执行完成（如仍有问题，后续安装仍会继续尝试）"
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

    echo "✅ [${pm}] 修复流程已执行完成（如仍有问题，后续安装仍会继续尝试）"
    return 0
}

fix_pkg_mgr() {
    local pm
    pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt) fix_pkg_mgr_apt ;;
        dnf) fix_pkg_mgr_yum_dnf "dnf" ;;
        yum) fix_pkg_mgr_yum_dnf "yum" ;;
        *)
            echo "⚠ 未识别到可用包管理器（apt/dnf/yum），跳过自动修复。"
            return 1
            ;;
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
        *)
            echo "❌ 无法安装：未找到 apt/dnf/yum"
            return 1
            ;;
    esac
}

ensure_curl() {
    if command -v curl &>/dev/null; then
        return
    fi
    echo "📦 未检测到 curl，正在安装..."
    fix_pkg_mgr || true
    install_pkgs curl
}

#-----------------------------
# 基础功能：Fail2ban / SSH 防爆破
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
        if [[ -z "$p" ]]; then
            echo "22"; return
        fi
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
    local port="$1"
    local action="$2"
    local logpath="$3"
    local maxretry="$4"
    local findtime="$5"
    local bantime="$6"

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
# 自动获取当前 SSH 来源 IP，并加入 ignoreip 白名单
#-----------------------------
get_current_ssh_client_ip() {
    if [[ -n "${SSH_CONNECTION-}" ]]; then
        awk '{print $1}' <<<"$SSH_CONNECTION"
        return 0
    fi
    if [[ -n "${SSH_CLIENT-}" ]]; then
        awk '{print $1}' <<<"$SSH_CLIENT"
        return 0
    fi
    return 1
}

add_ip_to_ignoreip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1

    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]]; then
        echo "⚠ 检测到的来源 IP 看起来不合法，跳过白名单：$ip"
        return 1
    fi

    mkdir -p /etc/fail2ban

    if [[ ! -f "$JAIL" ]]; then
        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $ip
EOF
        echo "✅ 已将当前 SSH 来源 IP 加入 ignoreip 白名单：$ip"
        return 0
    fi

    if ! grep -q "^\[DEFAULT\]" "$JAIL"; then
        local tmpf
        tmpf="$(mktemp)"
        {
            echo "[DEFAULT]"
            echo "ignoreip = 127.0.0.1/8 $ip"
            echo ""
            cat "$JAIL"
        } > "$tmpf" && mv "$tmpf" "$JAIL"
        echo "✅ 已将当前 SSH 来源 IP 加入 ignoreip 白名单：$ip"
        return 0
    fi

    local tmpfile
    tmpfile="$(mktemp)"
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

    echo "✅ 已将当前 SSH 来源 IP 加入/确认在 ignoreip 白名单：$ip"
    return 0
}

#-----------------------------
# fb5 安装（本地自安装优先，失败则远程下载兜底）
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
    echo "   你可以稍后在菜单 4 再次执行远程更新。"
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
    if ! ensure_fail2ban_ready; then
        pause
        return
    fi
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
    if ! ensure_fail2ban_ready; then
        pause
        return
    fi

    local ip=""
    read -rp "请输入要解禁的 IP（IPv4/IPv6，回车取消）: " ip
    if [[ -z "$ip" ]]; then
        echo "已取消。"
        pause
        return
    fi

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
    local fb_status="未知"
    local fb_enabled="未知"
    local sshd_jail="未知"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet fail2ban; then
            fb_status="运行中"
        else
            fb_status="未运行"
        fi

        if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
            fb_enabled="是"
        else
            fb_enabled="否"
        fi
    else
        fb_status="未知（无 systemd）"
        fb_enabled="未知"
    fi

    if command -v fail2ban-client &>/dev/null && command -v systemctl &>/dev/null && systemctl is-active --quiet fail2ban; then
        if fail2ban-client status sshd &>/dev/null; then
            sshd_jail="已启用"
        else
            sshd_jail="未启用"
        fi
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

    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 端口(记录于 fail2ban): $show_port"
    echo "快捷命令: $fb5_status"
    echo "SSH 白名单: $allow_status"
    echo "------------------------------------------------"
    echo ""
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
        local PM
        PM="$(detect_pkg_mgr)"

        if [[ "$PM" == "apt" ]]; then
            install_pkgs fail2ban
        elif [[ "$PM" == "dnf" || "$PM" == "yum" ]]; then
            if install_pkgs epel-release >/dev/null 2>&1; then
                echo "✅ 已尝试安装/启用 epel-release"
            else
                echo "ℹ️ epel-release 不可用或安装失败（将继续尝试安装 fail2ban）"
            fi
            install_pkgs fail2ban fail2ban-firewalld || install_pkgs fail2ban
        else
            echo "❌ 未识别包管理器，无法自动安装 Fail2ban。"
            pause
            return
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
    else
        echo "ℹ️ 未检测到 SSH 环境变量（可能是控制台执行），跳过自动白名单。"
    fi

    local ACTION
    ACTION="$(get_action_for_firewall)"

    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME
    CUR_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="3"
    CUR_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="21600"
    CUR_BANTIME="$(get_sshd_value bantime)";  [[ -z "$CUR_BANTIME"  ]] && CUR_BANTIME="12h"

    local LOGPATH
    LOGPATH="$(pick_ssh_logpath)"

    echo "🛡 写入/更新 SSH 防爆破配置到 jail.local（端口: $SSH_PORT）..."
    rewrite_or_append_sshd_block "$SSH_PORT" "$ACTION" "$LOGPATH" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    echo "🔄 重启 Fail2ban..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 是否有语法错误。"
        pause
        return
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
        pause
        return
    fi

    if ! grep -q "^\[sshd\]" "$JAIL"; then
        echo "⚠ jail.local 中没有 [sshd] 段，请先通过菜单 1 生成。"
        pause
        return
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
        pause
        return
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
        pause
        return
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

    read -rp "是否同时卸载 fail2ban 软件包？[y/N]: " CONFIRM2
    case "$CONFIRM2" in
        y|Y)
            local PM
            PM="$(detect_pkg_mgr)"
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
        pause
        return
    fi

    chmod +x "$INSTALL_CMD_PATH"
    echo "✅ 更新完成：$INSTALL_CMD_PATH"
    echo "👉 现在可直接运行：fb5"
    echo ""
    pause
}

# ============================================================
# 7. SSH 连接白名单（只允许白名单 IP 连接 SSH）
#   变更点：
#     - 添加/删除后立即应用（无需再点“立即应用”）
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
    if ! is_valid_ip_or_cidr "$ip"; then
        echo "⚠ IP 格式不正确：$ip"
        return 1
    fi
    if grep -Fxq "$ip" "$ALLOWLIST_FILE"; then
        return 0
    fi
    echo "$ip" >> "$ALLOWLIST_FILE"
    sort -u "$ALLOWLIST_FILE" -o "$ALLOWLIST_FILE" || true
    return 0
}

allowlist_del_ip() {
    local ip="$1"
    ensure_allowlist_storage
    if ! grep -Fxq "$ip" "$ALLOWLIST_FILE"; then
        return 1
    fi
    grep -Fxv "$ip" "$ALLOWLIST_FILE" > "${ALLOWLIST_FILE}.tmp" && mv "${ALLOWLIST_FILE}.tmp" "$ALLOWLIST_FILE"
    return 0
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

# --- 获取系统 SSH 端口：优先 fail2ban 配置，其次 sshd_config ---
get_effective_ssh_port() {
    local p=""
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        p="$(get_sshd_value port)"
    fi
    if [[ -z "$p" ]] && [[ -f /etc/ssh/sshd_config ]]; then
        p="$(awk '
            /^[[:space:]]*#/ {next}
            tolower($1)=="port" {print $2; exit}
        ' /etc/ssh/sshd_config 2>/dev/null)"
    fi
    [[ -z "$p" ]] && p="22"
    echo "$p"
}

# -----------------------------
# 防火墙应用/移除规则
# -----------------------------
apply_allowlist_rules_iptables() {
    local port="$1"
    ensure_allowlist_storage

    if ! command -v iptables >/dev/null 2>&1; then
        echo "❌ 未找到 iptables 命令，无法应用白名单规则。"
        return 1
    fi

    # 清理旧链与跳转（若存在）
    iptables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    iptables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    iptables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true

    # 新建链
    iptables -N "$IPTABLES_CHAIN" >/dev/null 2>&1 || true

    # 已建立连接放行
    iptables -A "$IPTABLES_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 放行白名单 IPv4
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" == *:* ]] && continue
        iptables -A "$IPTABLES_CHAIN" -s "$ip" -p tcp --dport "$port" -j ACCEPT
    done < "$ALLOWLIST_FILE"

    # 其余新连接丢弃
    iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j DROP

    # INPUT 前插入跳转
    iptables -I INPUT 1 -p tcp --dport "$port" -j "$IPTABLES_CHAIN"

    # IPv6（若存在）
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

    echo "✅ [iptables] 已应用 SSH 白名单规则（端口 $port）。"
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
    echo "✅ [iptables] 已移除 SSH 白名单限制（端口 $port）。"
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

    local v4_set=""
    local v6_set=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == *:* ]]; then
            v6_set+="${ip},"
        else
            v4_set+="${ip},"
        fi
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

    echo "✅ [nftables] 已应用 SSH 白名单规则（端口 $port）。"
    return 0
}

remove_allowlist_rules_nftables() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    echo "✅ [nftables] 已移除 SSH 白名单限制。"
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
        echo "   建议检查：systemctl status firewalld"
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

    echo "✅ [firewalld] 已应用 SSH 白名单规则（端口 $port）。"
    return 0
}

remove_allowlist_rules_firewalld() {
    local port="$1"
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        return 0
    fi

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

enable_allowlist_flag() {
    ensure_allowlist_storage
    : > "$ALLOWLIST_ENABLED_FLAG"
}

disable_allowlist_flag() {
    rm -f "$ALLOWLIST_ENABLED_FLAG" >/dev/null 2>&1 || true
}

# -----------------------------
# 追加/删除后“立即应用”的统一逻辑
# -----------------------------
apply_allowlist_immediately_or_disable_if_empty() {
    local port="$1"

    # 强制把当前 SSH 来源 IP 加入白名单，降低误锁
    local cur=""
    cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
    if [[ -n "$cur" ]]; then
        allowlist_add_ip "$cur" >/dev/null 2>&1 || true
    fi

    if [[ ! -s "$ALLOWLIST_FILE" ]]; then
        echo "⚠ 白名单已为空。为避免阻断所有 SSH 新连接，将自动关闭白名单限制。"
        remove_allowlist_rules "$port" || true
        disable_allowlist_flag
        return 0
    fi

    if apply_allowlist_rules "$port"; then
        enable_allowlist_flag
        echo "✅ 白名单规则已立即生效（端口 $port）。"
        return 0
    fi

    echo "❌ 白名单规则应用失败（请检查防火墙状态/权限/冲突规则）。"
    return 1
}

# -----------------------------
# 白名单菜单入口（新增/删除后立即生效）
# -----------------------------
ssh_allowlist_menu() {
    detect_firewall
    local port
    port="$(get_effective_ssh_port)"

    ensure_allowlist_storage

    while true; do
        clear
        echo "==============================================="
        echo " SSH 连接白名单（只允许白名单 IP 连接 SSH）"
        echo " 防火墙类型: $FIREWALL"
        echo " SSH 端口: $port"
        echo " 白名单文件: $ALLOWLIST_FILE"
        echo "==============================================="
        echo " 1) 查看当前白名单"
        echo " 2) 追加添加 IP（立刻生效；并自动加入当前 SSH 来源 IP）"
        echo " 3) 删除白名单 IP（立刻生效；若删空将自动关闭限制）"
        echo " 4) 关闭白名单限制（移除规则；保留列表文件）"
        echo " 0) 返回主菜单"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-4]: " C

        case "$C" in
            1)
                allowlist_show
                echo ""
                pause
                ;;
            2)
                local ip=""
                read -rp "请输入要允许 SSH 连接的 IP（如 1.1.1.1；回车取消）: " ip
                if [[ -z "$ip" ]]; then
                    echo "已取消。"
                    pause
                    continue
                fi
                if ! is_valid_ip_or_cidr "$ip"; then
                    echo "⚠ IP 格式不正确：$ip"
                    pause
                    continue
                fi

                # 加入用户输入 IP
                if allowlist_add_ip "$ip"; then
                    echo "✅ 已加入白名单：$ip"
                else
                    echo "❌ 加入失败：$ip"
                    pause
                    continue
                fi

                # 同时加入当前 SSH 来源 IP
                local cur=""
                cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
                if [[ -n "$cur" ]]; then
                    allowlist_add_ip "$cur" >/dev/null 2>&1 || true
                    echo "🧾 当前 SSH 来源 IP：$cur（已确保在白名单中）"
                else
                    echo "ℹ️ 未检测到 SSH 来源 IP（可能控制台执行），跳过自动加入。"
                fi

                echo ""
                echo "⚠ 将立即应用白名单规则：除白名单 IP 外，其他 IP 将无法建立新的 SSH 连接。"
                read -rp "确认继续吗？[y/N]: " ok
                case "$ok" in
                    y|Y) ;;
                    *) echo "已取消应用（但白名单列表已更新）。"; pause; continue ;;
                esac

                apply_allowlist_immediately_or_disable_if_empty "$port" || true
                echo ""
                pause
                ;;
            3)
                allowlist_show
                echo ""
                local dip=""
                read -rp "请输入要删除的 IP（需与列表完全一致；回车取消）: " dip
                if [[ -z "$dip" ]]; then
                    echo "已取消。"
                    pause
                    continue
                fi

                # 若用户尝试删除当前 SSH 来源 IP，提示风险
                local cur2=""
                cur2="$(get_current_ssh_client_ip 2>/dev/null || true)"
                if [[ -n "$cur2" && "$dip" == "$cur2" ]]; then
                    echo "⚠ 你正在删除当前 SSH 来源 IP：$cur2"
                    echo "   这可能导致你断开后无法重新连接（虽然当前连接通常不会立刻断）。"
                    read -rp "仍要继续删除并立即生效吗？[y/N]: " risk
                    case "$risk" in
                        y|Y) ;;
                        *) echo "已取消。"; pause; continue ;;
                    esac
                fi

                if allowlist_del_ip "$dip"; then
                    echo "✅ 已从白名单删除：$dip"
                else
                    echo "⚠ 白名单中不存在：$dip"
                    pause
                    continue
                fi

                # 删除后立即重新应用（并会自动把当前 SSH 来源 IP 重新加入，除非用户刚刚确认删除它）
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
                remove_allowlist_rules "$port" || true
                disable_allowlist_flag
                echo ""
                pause
                ;;
            0)
                return
                ;;
            *)
                echo "❌ 无效选项。"
                pause
                ;;
        esac
    done
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
        echo " 1) 安装 / 配置 SSH 防爆破（自动白名单当前 SSH IP + 自动安装 fb5）"
        echo " 2) 快捷修改 SSH 防爆破参数（失败次数 / 封禁时长 / 检测周期）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 4) 远程更新 fb5 脚本（仅更新功能）"
        echo " 5) 查看 sshd 封禁 IP 列表"
        echo " 6) 解禁指定 IP（sshd）"
        echo " 7) SSH 连接白名单（新增/删除后立即生效）"
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

ensure_root
main_menu
