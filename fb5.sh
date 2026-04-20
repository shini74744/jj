#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector 菜单版 + 3x-ui 扩展版（修复版）
#
# 功能：
#   1) 安装 / 配置 SSH 防爆破
#   2) 快捷修改 SSH 防爆破参数
#   3) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#   4) 从远程更新 fb5 脚本
#   5) 查看当前封禁 IP 列表（sshd）
#   6) 解禁指定 IP（sshd）
#   7) 启用 / 配置 3x-ui TLS 扫描封禁（整机拦）
#   8) 修改 3x-ui TLS 扫描封禁参数（可改端口）
#   9) 查看 3x-ui TLS 扫描封禁 IP 列表
#  10) 解禁指定 IP（3xui-tls）
#  11) 启用 / 配置 3x-ui 登录失败封禁（整机拦）
#  12) 修改 3x-ui 登录失败封禁参数（可改端口）
#  13) 查看 3x-ui 登录失败封禁 IP 列表
#  14) 解禁指定 IP（3xui-login）
#
# 说明：
#   - SSH / 3xui-tls / 3xui-login 三套规则完全独立
#   - 3x-ui 两套 jail 被 ban 后会整机拦截该 IP
#   - 3x-ui 两套规则依赖 systemd journal（backend = systemd）
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

XUI_SERVICE_NAME="x-ui.service"

XUI_TLS_FILTER="/etc/fail2ban/filter.d/3xui-tls.conf"
XUI_TLS_JAIL="/etc/fail2ban/jail.d/3xui-tls.local"

XUI_LOGIN_FILTER="/etc/fail2ban/filter.d/3xui-login.conf"
XUI_LOGIN_JAIL="/etc/fail2ban/jail.d/3xui-login.local"

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
            rhel) OS="rhel" ;;
            rocky) OS="rocky" ;;
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
    elif grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        OS="ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        OS="debian"
    else
        OS="unknown"
    fi
}

detect_firewall() {
    if [[ -n "$FIREWALL" ]]; then return; fi

    # 优先判断 firewalld；否则判断 nft；否则回落 iptables
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALL="firewalld"
    elif command -v nft &>/dev/null; then
        FIREWALL="nftables"
    else
        FIREWALL="iptables"
    fi
}

#-----------------------------
# 包管理器：探测 / 修复 / 安装
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
# Fail2ban action 选择（修复版）
#-----------------------------
get_ssh_action_for_firewall() {
    detect_firewall
    case "$FIREWALL" in
        nftables)
            echo "nftables[type=multiport]"
            ;;
        firewalld)
            echo "firewallcmd-ipset[actiontype=<multiport>]"
            ;;
        *)
            echo "iptables[type=multiport]"
            ;;
    esac
}

get_xui_allports_action_for_firewall() {
    detect_firewall
    case "$FIREWALL" in
        nftables)
            echo "nftables[type=allports, protocol=tcp,udp]"
            ;;
        firewalld)
            # 空 actiontype = block all attempts from the host
            echo 'firewallcmd-ipset[actiontype=""]'
            ;;
        *)
            echo "iptables[type=allports, protocol=tcp,udp]"
            ;;
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
            echo "22"
            return
        fi
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
            echo "$p"
            return
        fi
        echo "⚠ 端口号无效，请输入 1-65535 的整数，或直接回车默认 22。"
    done
}

prompt_xui_port() {
    local p=""
    while true; do
        read -rp "请输入 3x-ui 面板端口号（必填，例如 744 / 2053 / 54321）: " p
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
            echo "$p"
            return
        fi
        echo "⚠ 端口号无效，请输入 1-65535 的整数。"
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

get_ini_value_from_file() {
    local file="$1"
    local section="$2"
    local key="$3"

    [[ ! -f "$file" ]] && return 0

    awk -v sec="$section" -v k="$key" '
        BEGIN{in_sec=0}
        $0 ~ "^\\[" sec "\\]$" {in_sec=1; next}
        /^\[.*\]$/ {if(in_sec){in_sec=0}}
        in_sec {
            if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", $0)
                sub("[[:space:]]*$", "", $0)
                print $0
            }
        }
    ' "$file" | tail -n1
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

    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
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

build_xui_ignoreip() {
    local ips="127.0.0.1/8 ::1"
    local cur_ip=""
    cur_ip="$(get_current_ssh_client_ip 2>/dev/null || true)"

    if [[ -n "$cur_ip" ]] && [[ "$cur_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        ips="$ips $cur_ip"
    fi

    echo "$ips"
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
# Fail2ban 状态检查
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

ensure_jail_ready() {
    local jail_name="$1"

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

    if ! fail2ban-client status "$jail_name" &>/dev/null; then
        echo "❌ $jail_name jail 未启用或无法查询。"
        return 1
    fi

    return 0
}

ensure_xui_fail2ban_env() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "❌ 未检测到 fail2ban-client，请先执行菜单 1 安装/配置 Fail2ban。"
        return 1
    fi

    if ! command -v systemctl &>/dev/null; then
        echo "❌ 3x-ui 日志封禁功能依赖 systemd journal，当前系统未检测到 systemctl。"
        return 1
    fi

    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

    if ! systemctl status x-ui >/dev/null 2>&1; then
        echo "⚠ 未检测到 x-ui 服务正在运行，仍会写入规则，但请确认服务名确实是 x-ui。"
        echo "   你可以手动检查：systemctl status x-ui"
    fi

    return 0
}

restart_fail2ban_or_return() {
    echo "🔄 重启 Fail2ban..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查新写入的规则文件语法。"
        echo ""
        echo "👉 最近 30 行 Fail2ban 日志："
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || true
        pause
        return 1
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true
    return 0
}

show_jail_simple_status() {
    local jail_name="$1"
    local i=0

    echo ""
    echo "================ ${jail_name} 状态 ================"

    for i in 1 2 3; do
        if fail2ban-client status "$jail_name" 2>/dev/null; then
            echo "=================================================="
            echo ""
            return 0
        fi
        sleep 1
    done

    echo "⚠ 暂时无法读取 $jail_name 状态"
    echo "👉 当前 Fail2ban 总状态："
    fail2ban-client status 2>/dev/null || true
    echo "=================================================="
    echo ""
    return 1
}

#-----------------------------
# 通用：查看 / 解禁指定 jail 的 IP
#-----------------------------
view_banned_ips_for_jail() {
    local jail_name="$1"
    local title="$2"

    if ! ensure_jail_ready "$jail_name"; then
        pause
        return
    fi

    echo "================ ${title} 当前封禁 IP ================"
    if fail2ban-client get "$jail_name" banip &>/dev/null; then
        local ips
        ips="$(fail2ban-client get "$jail_name" banip | tr -s ' ' | sed 's/^ *//;s/ *$//')"
        if [[ -z "$ips" ]]; then
            echo "✅ 当前无封禁 IP"
        else
            echo "$ips" | tr ' ' '\n'
        fi
    else
        echo "（当前 fail2ban-client 不支持 get banip，改用 status 输出）"
        fail2ban-client status "$jail_name" || true
    fi
    echo "====================================================="
    echo ""
    pause
}

unban_ip_for_jail() {
    local jail_name="$1"
    local title="$2"

    if ! ensure_jail_ready "$jail_name"; then
        pause
        return
    fi

    local ip=""
    read -rp "请输入要从 ${title} 解禁的 IP（IPv4/IPv6，回车取消）: " ip
    if [[ -z "$ip" ]]; then
        echo "已取消。"
        pause
        return
    fi

    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        echo "⚠ IP 格式看起来不正确：$ip"
        pause
        return
    fi

    if fail2ban-client set "$jail_name" unbanip "$ip" >/dev/null 2>&1; then
        echo "✅ 已从 ${title} 解禁：$ip"
    else
        echo "❌ 解禁失败：$ip"
        echo "   可能原因：该 IP 不在封禁列表中，或 fail2ban 运行异常。"
    fi

    echo ""
    pause
}

#-----------------------------
# XUI jail 文件写入器
#-----------------------------
write_3xui_tls_files() {
    local panel_port="$1"
    local action="$2"
    local ignoreips="$3"
    local maxretry="$4"
    local findtime="$5"
    local bantime="$6"

    cat > "$XUI_TLS_FILTER" <<'EOF'
[Definition]
failregex = ^.*http: TLS handshake error from <HOST>:\d+:.*$
ignoreregex =
EOF

    cat > "$XUI_TLS_JAIL" <<EOF
[3xui-tls]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=${XUI_SERVICE_NAME}
filter = 3xui-tls
port = $panel_port
protocol = tcp,udp
maxretry = $maxretry
findtime = $findtime
bantime = $bantime
ignoreip = $ignoreips
action = $action
EOF
}

write_3xui_login_files() {
    local panel_port="$1"
    local action="$2"
    local ignoreips="$3"
    local maxretry="$4"
    local findtime="$5"
    local bantime="$6"

    cat > "$XUI_LOGIN_FILTER" <<'EOF'
[Definition]
failregex = ^.*WARNING - wrong username: .*IP:\s*"<HOST>"\s*$
ignoreregex =
EOF

    cat > "$XUI_LOGIN_JAIL" <<EOF
[3xui-login]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=${XUI_SERVICE_NAME}
filter = 3xui-login
port = $panel_port
protocol = tcp,udp
maxretry = $maxretry
findtime = $findtime
bantime = $bantime
ignoreip = $ignoreips
action = $action
EOF
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

    if [[ "$ip" =~ [[:space:]] ]] || ! [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
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
# 状态总览：面板状态 / 开机启动 / jail 状态
#-----------------------------
print_status_summary() {
    echo "---------------- 当前运行状态 ----------------"
    local fb_status="未知"
    local fb_enabled="未知"
    local sshd_jail="未知"
    local xui_tls_jail="未启用"
    local xui_login_jail="未启用"

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

        if fail2ban-client status 3xui-tls &>/dev/null; then
            xui_tls_jail="已启用"
        fi

        if fail2ban-client status 3xui-login &>/dev/null; then
            xui_login_jail="已启用"
        fi
    elif ! command -v fail2ban-client &>/dev/null; then
        sshd_jail="未知（未安装 Fail2ban）"
        xui_tls_jail="未知（未安装 Fail2ban）"
        xui_login_jail="未知（未安装 Fail2ban）"
    else
        sshd_jail="未知（Fail2ban 未运行）"
        xui_tls_jail="未知（Fail2ban 未运行）"
        xui_login_jail="未知（Fail2ban 未运行）"
    fi

    local show_port="—"
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        show_port="$(get_sshd_value port)"
        [[ -z "$show_port" ]] && show_port="—"
    fi

    local xui_tls_port="—"
    [[ -f "$XUI_TLS_JAIL" ]] && xui_tls_port="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "port")"
    [[ -z "$xui_tls_port" ]] && xui_tls_port="—"

    local xui_login_port="—"
    [[ -f "$XUI_LOGIN_JAIL" ]] && xui_login_port="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "port")"
    [[ -z "$xui_login_port" ]] && xui_login_port="—"

    local fb5_status="未安装"
    [[ -x "$INSTALL_CMD_PATH" ]] && fb5_status="已安装($INSTALL_CMD_PATH)"

    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 端口(记录于 fail2ban): $show_port"
    echo "3x-ui TLS 扫描封禁: $xui_tls_jail (记录端口: $xui_tls_port, 被 ban 后整机拦)"
    echo "3x-ui 登录失败封禁: $xui_login_jail (记录端口: $xui_login_port, 被 ban 后整机拦)"
    echo "快捷命令: $fb5_status"
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
    ACTION="$(get_ssh_action_for_firewall)"

    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME
    CUR_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="3"
    CUR_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="21600"
    CUR_BANTIME="$(get_sshd_value bantime)";  [[ -z "$CUR_BANTIME"  ]] && CUR_BANTIME="12h"

    local LOGPATH
    LOGPATH="$(pick_ssh_logpath)"

    echo "🛡 写入/更新 SSH 防爆破配置到 jail.local（端口: $SSH_PORT）..."
    rewrite_or_append_sshd_block "$SSH_PORT" "$ACTION" "$LOGPATH" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

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
    ACTION="$(get_ssh_action_for_firewall)"
    LOGPATH="$(get_sshd_value logpath)"
    [[ -z "$LOGPATH" ]] && LOGPATH="$(pick_ssh_logpath)"

    echo "🛠 更新 [sshd] 段..."
    rewrite_or_append_sshd_block "$CURRENT_PORT" "$ACTION" "$LOGPATH" "$FINAL_MAXRETRY" "$FINAL_FINDTIME" "$FINAL_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

    echo ""
    echo "✅ 修改已生效！"
    print_status_summary
    echo ""
    pause
}

#-----------------------------
# 7. 启用 / 配置 3x-ui TLS 扫描封禁（整机拦）
#-----------------------------
enable_3xui_tls_protection() {
    if ! ensure_xui_fail2ban_env; then
        pause
        return
    fi

    detect_firewall

    local PANEL_PORT ACTION IGNOREIPS
    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME

    PANEL_PORT="$(prompt_xui_port)"
    ACTION="$(get_xui_allports_action_for_firewall)"
    IGNOREIPS="$(build_xui_ignoreip)"

    CUR_MAXRETRY="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "maxretry")"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="8"
    CUR_FINDTIME="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "findtime")"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="300"
    CUR_BANTIME="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "bantime")"; [[ -z "$CUR_BANTIME" ]] && CUR_BANTIME="6h"

    echo "🛡 正在启用 / 更新 3x-ui TLS 异常扫描封禁（被 ban 后整机拦）..."
    echo "   记录端口: $PANEL_PORT"
    echo "   防火墙动作: $ACTION"
    echo "   白名单: $IGNOREIPS"
    echo "   maxretry: $CUR_MAXRETRY"
    echo "   findtime: $CUR_FINDTIME"
    echo "   bantime: $CUR_BANTIME"
    echo ""

    write_3xui_tls_files "$PANEL_PORT" "$ACTION" "$IGNOREIPS" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

    echo "✅ 3x-ui TLS 扫描封禁已启用。"
    echo "   当前策略：${CUR_FINDTIME} 秒内达到 ${CUR_MAXRETRY} 次 TLS 握手异常，则封禁 ${CUR_BANTIME}。"
    show_jail_simple_status "3xui-tls"
    pause
}

#-----------------------------
# 8. 修改 3x-ui TLS 扫描封禁参数（可改端口）
#-----------------------------
modify_3xui_tls_params() {
    if [[ ! -f "$XUI_TLS_JAIL" ]]; then
        echo "⚠ 未检测到 $XUI_TLS_JAIL，请先执行『7) 启用 / 配置 3x-ui TLS 扫描封禁』"
        pause
        return
    fi

    local CURRENT_PORT CURRENT_MAXRETRY CURRENT_FINDTIME CURRENT_BANTIME CURRENT_IGNOREIP
    CURRENT_PORT="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "port")"; [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="744"
    CURRENT_MAXRETRY="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "maxretry")"; [[ -z "$CURRENT_MAXRETRY" ]] && CURRENT_MAXRETRY="8"
    CURRENT_FINDTIME="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "findtime")"; [[ -z "$CURRENT_FINDTIME" ]] && CURRENT_FINDTIME="300"
    CURRENT_BANTIME="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "bantime")"; [[ -z "$CURRENT_BANTIME" ]] && CURRENT_BANTIME="6h"
    CURRENT_IGNOREIP="$(get_ini_value_from_file "$XUI_TLS_JAIL" "3xui-tls" "ignoreip")"; [[ -z "$CURRENT_IGNOREIP" ]] && CURRENT_IGNOREIP="$(build_xui_ignoreip)"

    echo "================ 修改 3x-ui TLS 扫描封禁参数 ================"
    echo "当前配置："
    echo "  port（记录端口）       : $CURRENT_PORT"
    echo "  maxretry（失败次数）   : $CURRENT_MAXRETRY"
    echo "  bantime（封禁时长）    : $CURRENT_BANTIME"
    echo "  findtime（检测周期 秒）: $CURRENT_FINDTIME"
    echo "-------------------------------------------------------------"
    echo "留空则表示不修改该项。"
    echo "bantime 支持格式：600、12h、1d"
    echo "findtime 用秒数，比如 300 表示 5 分钟。"
    echo "============================================================="
    echo ""

    read -rp "请输入新的记录端口（例：744，留空不改）： " NEW_PORT
    read -rp "请输入新的 maxretry（失败次数，例：8，留空不改）： " NEW_MAXRETRY
    read -rp "请输入新的 bantime（封禁时长，例：6h 或 3600，留空不改）： " NEW_BANTIME
    read -rp "请输入新的 findtime（检测周期秒数，例：300，留空不改）： " NEW_FINDTIME

    if [[ -z "$NEW_PORT" && -z "$NEW_MAXRETRY" && -z "$NEW_BANTIME" && -z "$NEW_FINDTIME" ]]; then
        echo "ℹ️ 未输入任何修改，保持原样。"
        pause
        return
    fi

    local FINAL_PORT FINAL_MAXRETRY FINAL_BANTIME FINAL_FINDTIME
    FINAL_PORT="$CURRENT_PORT"
    FINAL_MAXRETRY="$CURRENT_MAXRETRY"
    FINAL_BANTIME="$CURRENT_BANTIME"
    FINAL_FINDTIME="$CURRENT_FINDTIME"

    if [[ -n "$NEW_PORT" ]]; then
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || ! (( NEW_PORT >= 1 && NEW_PORT <= 65535 )); then
            echo "⚠ 端口必须是 1-65535 的整数，已忽略该项修改。"
        else
            FINAL_PORT="$NEW_PORT"
            echo "✅ 记录端口将修改为：$FINAL_PORT"
        fi
    fi

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

    local ACTION
    ACTION="$(get_xui_allports_action_for_firewall)"
    write_3xui_tls_files "$FINAL_PORT" "$ACTION" "$CURRENT_IGNOREIP" "$FINAL_MAXRETRY" "$FINAL_FINDTIME" "$FINAL_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

    echo "✅ 3x-ui TLS 扫描封禁参数已更新。"
    show_jail_simple_status "3xui-tls"
    pause
}

#-----------------------------
# 9. 查看 3x-ui TLS 扫描封禁 IP 列表
#-----------------------------
view_3xui_tls_banned_ips() {
    view_banned_ips_for_jail "3xui-tls" "3xui-tls"
}

#-----------------------------
# 10. 解禁指定 IP（3xui-tls）
#-----------------------------
unban_3xui_tls_ip() {
    unban_ip_for_jail "3xui-tls" "3xui-tls"
}

#-----------------------------
# 11. 启用 / 配置 3x-ui 登录失败封禁（整机拦）
#-----------------------------
enable_3xui_login_protection() {
    if ! ensure_xui_fail2ban_env; then
        pause
        return
    fi

    detect_firewall

    local PANEL_PORT ACTION IGNOREIPS
    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME

    PANEL_PORT="$(prompt_xui_port)"
    ACTION="$(get_xui_allports_action_for_firewall)"
    IGNOREIPS="$(build_xui_ignoreip)"

    CUR_MAXRETRY="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "maxretry")"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="5"
    CUR_FINDTIME="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "findtime")"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="600"
    CUR_BANTIME="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "bantime")"; [[ -z "$CUR_BANTIME" ]] && CUR_BANTIME="12h"

    echo "🛡 正在启用 / 更新 3x-ui 面板登录失败封禁（被 ban 后整机拦）..."
    echo "   记录端口: $PANEL_PORT"
    echo "   防火墙动作: $ACTION"
    echo "   白名单: $IGNOREIPS"
    echo "   maxretry: $CUR_MAXRETRY"
    echo "   findtime: $CUR_FINDTIME"
    echo "   bantime: $CUR_BANTIME"
    echo ""

    write_3xui_login_files "$PANEL_PORT" "$ACTION" "$IGNOREIPS" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

    echo "✅ 3x-ui 登录失败封禁已启用。"
    echo "   当前策略：${CUR_FINDTIME} 秒内达到 ${CUR_MAXRETRY} 次错误登录，则封禁 ${CUR_BANTIME}。"
    echo "⚠ 注意：请确认 3x-ui 失败登录日志里的 IP 是真实来访 IP。"
    show_jail_simple_status "3xui-login"
    pause
}

#-----------------------------
# 12. 修改 3x-ui 登录失败封禁参数（可改端口）
#-----------------------------
modify_3xui_login_params() {
    if [[ ! -f "$XUI_LOGIN_JAIL" ]]; then
        echo "⚠ 未检测到 $XUI_LOGIN_JAIL，请先执行『11) 启用 / 配置 3x-ui 登录失败封禁』"
        pause
        return
    fi

    local CURRENT_PORT CURRENT_MAXRETRY CURRENT_FINDTIME CURRENT_BANTIME CURRENT_IGNOREIP
    CURRENT_PORT="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "port")"; [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="744"
    CURRENT_MAXRETRY="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "maxretry")"; [[ -z "$CURRENT_MAXRETRY" ]] && CURRENT_MAXRETRY="5"
    CURRENT_FINDTIME="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "findtime")"; [[ -z "$CURRENT_FINDTIME" ]] && CURRENT_FINDTIME="600"
    CURRENT_BANTIME="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "bantime")"; [[ -z "$CURRENT_BANTIME" ]] && CURRENT_BANTIME="12h"
    CURRENT_IGNOREIP="$(get_ini_value_from_file "$XUI_LOGIN_JAIL" "3xui-login" "ignoreip")"; [[ -z "$CURRENT_IGNOREIP" ]] && CURRENT_IGNOREIP="$(build_xui_ignoreip)"

    echo "================ 修改 3x-ui 登录失败封禁参数 ================"
    echo "当前配置："
    echo "  port（记录端口）       : $CURRENT_PORT"
    echo "  maxretry（失败次数）   : $CURRENT_MAXRETRY"
    echo "  bantime（封禁时长）    : $CURRENT_BANTIME"
    echo "  findtime（检测周期 秒）: $CURRENT_FINDTIME"
    echo "-------------------------------------------------------------"
    echo "留空则表示不修改该项。"
    echo "bantime 支持格式：600、12h、1d"
    echo "findtime 用秒数，比如 600 表示 10 分钟。"
    echo "============================================================="
    echo ""

    read -rp "请输入新的记录端口（例：744，留空不改）： " NEW_PORT
    read -rp "请输入新的 maxretry（失败次数，例：5，留空不改）： " NEW_MAXRETRY
    read -rp "请输入新的 bantime（封禁时长，例：12h 或 3600，留空不改）： " NEW_BANTIME
    read -rp "请输入新的 findtime（检测周期秒数，例：600，留空不改）： " NEW_FINDTIME

    if [[ -z "$NEW_PORT" && -z "$NEW_MAXRETRY" && -z "$NEW_BANTIME" && -z "$NEW_FINDTIME" ]]; then
        echo "ℹ️ 未输入任何修改，保持原样。"
        pause
        return
    fi

    local FINAL_PORT FINAL_MAXRETRY FINAL_BANTIME FINAL_FINDTIME
    FINAL_PORT="$CURRENT_PORT"
    FINAL_MAXRETRY="$CURRENT_MAXRETRY"
    FINAL_BANTIME="$CURRENT_BANTIME"
    FINAL_FINDTIME="$CURRENT_FINDTIME"

    if [[ -n "$NEW_PORT" ]]; then
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || ! (( NEW_PORT >= 1 && NEW_PORT <= 65535 )); then
            echo "⚠ 端口必须是 1-65535 的整数，已忽略该项修改。"
        else
            FINAL_PORT="$NEW_PORT"
            echo "✅ 记录端口将修改为：$FINAL_PORT"
        fi
    fi

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

    local ACTION
    ACTION="$(get_xui_allports_action_for_firewall)"
    write_3xui_login_files "$FINAL_PORT" "$ACTION" "$CURRENT_IGNOREIP" "$FINAL_MAXRETRY" "$FINAL_FINDTIME" "$FINAL_BANTIME"

    if ! restart_fail2ban_or_return; then
        return
    fi

    echo "✅ 3x-ui 登录失败封禁参数已更新。"
    show_jail_simple_status "3xui-login"
    pause
}

#-----------------------------
# 13. 查看 3x-ui 登录失败封禁 IP 列表
#-----------------------------
view_3xui_login_banned_ips() {
    view_banned_ips_for_jail "3xui-login" "3xui-login"
}

#-----------------------------
# 14. 解禁指定 IP（3xui-login）
#-----------------------------
unban_3xui_login_ip() {
    unban_ip_for_jail "3xui-login" "3xui-login"
}

#-----------------------------
# 3. 卸载本脚本相关配置
#-----------------------------
uninstall_all() {
    echo "⚠ 此操作将删除："
    echo "   - /etc/fail2ban/jail.local（若存在，会直接删除整个文件）"
    echo "   - $XUI_TLS_FILTER"
    echo "   - $XUI_TLS_JAIL"
    echo "   - $XUI_LOGIN_FILTER"
    echo "   - $XUI_LOGIN_JAIL"
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

    rm -f /etc/fail2ban/jail.local
    rm -f "$XUI_TLS_FILTER" "$XUI_TLS_JAIL" "$XUI_LOGIN_FILTER" "$XUI_LOGIN_JAIL"
    echo "✅ 本脚本相关 Fail2ban 配置文件已删除。"

    read -rp "是否同时卸载 fail2ban 软件包？[y/N]: " CONFIRM2
    case "$CONFIRM2" in
        y|Y)
            systemctl stop fail2ban 2>/dev/null || true
            detect_os
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
        *)
            if command -v systemctl &>/dev/null; then
                systemctl restart fail2ban 2>/dev/null || true
                systemctl enable fail2ban >/dev/null 2>&1 || true
            fi
            echo "已保留 fail2ban 软件包（但已删除本脚本配置）。"
            ;;
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

#-----------------------------
# 主菜单
#-----------------------------
main_menu() {
    while true; do
        clear
        echo "=========================================================="
        echo " Fail2ban SSH / 3x-ui 防爆破 管理脚本（修复版）"
        echo "=========================================================="
        print_status_summary
        echo " 1) 安装 / 配置 SSH 防爆破（自动白名单当前 SSH IP + 自动安装 fb5）"
        echo " 2) 快捷修改 SSH 防爆破参数（失败次数 / 封禁时长 / 检测周期）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 4) 远程更新 fb5 脚本（仅更新功能）"
        echo " 5) 查看 sshd 封禁 IP 列表"
        echo " 6) 解禁指定 IP（sshd）"
        echo " 7) 启用 / 配置 3x-ui TLS 扫描封禁（被 ban 后整机拦）"
        echo " 8) 修改 3x-ui TLS 扫描封禁参数（可改端口）"
        echo " 9) 查看 3x-ui TLS 扫描封禁 IP 列表"
        echo "10) 解禁指定 IP（3xui-tls）"
        echo "11) 启用 / 配置 3x-ui 登录失败封禁（被 ban 后整机拦）"
        echo "12) 修改 3x-ui 登录失败封禁参数（可改端口）"
        echo "13) 查看 3x-ui 登录失败封禁 IP 列表"
        echo "14) 解禁指定 IP（3xui-login）"
        echo " 0) 退出"
        echo "----------------------------------------------------------"
        read -rp "请输入选项 [0-14]: " CHOICE
        case "$CHOICE" in
            1) install_or_config_ssh ;;
            2) modify_ssh_params ;;
            3) uninstall_all ;;
            4) update_fb5_from_remote ;;
            5) view_banned_ips ;;
            6) unban_ip ;;
            7) enable_3xui_tls_protection ;;
            8) modify_3xui_tls_params ;;
            9) view_3xui_tls_banned_ips ;;
            10) unban_3xui_tls_ip ;;
            11) enable_3xui_login_protection ;;
            12) modify_3xui_login_params ;;
            13) view_3xui_login_banned_ips ;;
            14) unban_3xui_login_ip ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "❌ 无效选项。"; pause ;;
        esac
    done
}

ensure_root
main_menu
