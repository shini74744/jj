#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector 菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 关键修复：
#   - systemd 兜底(B)始终可用：开机自动执行 fb5 --apply-allowlist
#   - 防止 systemd 进入菜单：非交互入口 --apply-allowlist
#   - 如果 /usr/local/bin/fb5 不是新版本（无 --apply-allowlist），自动覆盖安装
#   - clear 仅在 TTY 环境执行，避免 TERM 报错
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

# nftables
NFT_TABLE="fb5"
NFT_FAMILY="inet"
NFT_PERSIST_DIR="/etc/nftables.d"
NFT_PERSIST_FILE="${NFT_PERSIST_DIR}/fb5-ssh-allow.nft"
NFT_MAIN_CONF="/etc/nftables.conf"

# firewalld
FIREWALLD_IPSET="fb5-ssh-allow"

# systemd 兜底(B)
SYSTEMD_UNIT="/etc/systemd/system/fb5-ssh-allowlist.service"

#-----------------------------
# 小工具：仅在TTY clear，避免 TERM 报错
#-----------------------------
safe_clear() {
    if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

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
    if [[ -f /etc/redhat-release ]]; then OS="rhellike"; else OS="unknown"; fi
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
# 包管理器：稳健安装
#-----------------------------
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    else echo "unknown"
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
            echo "⚠ apt/dpkg 锁仍被占用（等待 ${max_wait}s 超时），继续后续流程。"
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 0
}

fix_pkg_mgr() {
    local pm; pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt)
            wait_for_apt_locks 180 || true
            dpkg --configure -a || true
            apt-get -y -f install || true
            apt-get -y clean || true
            apt-get update -y || true
            ;;
        dnf)
            dnf -y clean all || true
            dnf -y makecache || true
            rpm --rebuilddb >/dev/null 2>&1 || true
            ;;
        yum)
            yum -y clean all || true
            yum -y makecache || true
            if command -v yum-complete-transaction >/dev/null 2>&1; then
                yum-complete-transaction -y || true
            fi
            rpm --rebuilddb >/dev/null 2>&1 || true
            ;;
        *) return 1 ;;
    esac
    return 0
}

install_pkgs() {
    local pm; pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt)
            wait_for_apt_locks 180 || true
            apt-get update -y || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || {
                fix_pkg_mgr || true
                wait_for_apt_locks 180 || true
                apt-get update -y || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            }
            ;;
        dnf)
            dnf -y install "$@" || { fix_pkg_mgr || true; dnf -y install "$@"; }
            ;;
        yum)
            yum -y install "$@" || { fix_pkg_mgr || true; yum -y install "$@"; }
            ;;
        *) echo "❌ 未识别包管理器，无法安装：$*"; return 1 ;;
    esac
}

ensure_curl() {
    command -v curl &>/dev/null && return 0
    fix_pkg_mgr || true
    install_pkgs curl
}

#-----------------------------
# SSH / Fail2ban helpers
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
    (( ${#paths[@]} == 0 )) && { echo "/var/log/auth.log /var/log/secure"; return; }
    echo "${paths[*]}"
}

prompt_ssh_port() {
    local p=""
    while true; do
        read -rp "请输入 SSH 端口号（回车默认 22）: " p
        [[ -z "$p" ]] && { echo "22"; return; }
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then echo "$p"; return; fi
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
    mkdir -p /etc/fail2ban
    [[ -f "$JAIL" ]] || touch "$JAIL"

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

    local tmpfile; tmpfile="$(mktemp)"
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

get_current_ssh_client_ip() {
    [[ -n "${SSH_CONNECTION-}" ]] && { awk '{print $1}' <<<"$SSH_CONNECTION"; return 0; }
    [[ -n "${SSH_CLIENT-}" ]] && { awk '{print $1}' <<<"$SSH_CLIENT"; return 0; }
    return 1
}

get_current_session_ssh_port() {
    [[ -n "${SSH_CONNECTION-}" ]] && { awk '{print $4}' <<<"$SSH_CONNECTION" | grep -E '^[0-9]+$' || true; return 0; }
    return 1
}

add_ip_to_ignoreip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" =~ [[:space:]] ]] && return 1
    [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]] || return 1

    mkdir -p /etc/fail2ban
    if [[ ! -f "$JAIL" ]]; then
        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $ip
EOF
        return 0
    fi

    if ! grep -q "^\[DEFAULT\]" "$JAIL"; then
        local tmpf; tmpf="$(mktemp)"
        { echo "[DEFAULT]"; echo "ignoreip = 127.0.0.1/8 $ip"; echo ""; cat "$JAIL"; } > "$tmpf" && mv "$tmpf" "$JAIL"
        return 0
    fi

    local tmpfile; tmpfile="$(mktemp)"
    awk -v ip="$ip" '
        function has_ip(line, x){ return (index(" " line " ", " " x " ") > 0) }
        BEGIN{in_def=0; has_ignore=0}
        /^\[DEFAULT\]$/ {in_def=1; print; next}
        /^\[/ && $0 !~ /^\[DEFAULT\]$/ {
            if(in_def && has_ignore==0){ print "ignoreip = 127.0.0.1/8 " ip }
            in_def=0; print; next
        }
        {
            if(in_def && $0 ~ /^ignoreip[[:space:]]*=/){
                has_ignore=1
                if(has_ip($0, ip)) print
                else print $0 " " ip
                next
            }
            print
        }
        END{ if(in_def && has_ignore==0) print "ignoreip = 127.0.0.1/8 " ip }
    ' "$JAIL" > "$tmpfile" && mv "$tmpfile" "$JAIL"
    return 0
}

#-----------------------------
# fb5 安装：保证 /usr/local/bin/fb5 一定是新版本
#-----------------------------
fb5_supports_apply() {
    [[ -x "$INSTALL_CMD_PATH" ]] && grep -q -- "--apply-allowlist" "$INSTALL_CMD_PATH" 2>/dev/null
}

install_fb5_now() {
    mkdir -p "$(dirname "$INSTALL_CMD_PATH")"

    # 优先复制“当前运行的脚本文件”
    local src="$0"
    if command -v readlink &>/dev/null; then
        src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    fi

    if [[ -f "$src" ]]; then
        cp -f "$src" "$INSTALL_CMD_PATH"
        chmod +x "$INSTALL_CMD_PATH"
        return 0
    fi

    # 兜底：远程下载
    ensure_curl
    curl -fsSL "$REMOTE_URL" -o "$INSTALL_CMD_PATH"
    chmod +x "$INSTALL_CMD_PATH"
    return 0
}

ensure_fb5_is_new() {
    # 若不存在或不支持 --apply-allowlist，强制覆盖安装
    if ! fb5_supports_apply; then
        install_fb5_now || true
    fi
    fb5_supports_apply
}

#-----------------------------
# Fail2ban 状态（5/6）
#-----------------------------
ensure_fail2ban_ready() {
    command -v fail2ban-client &>/dev/null || { echo "❌ 未检测到 fail2ban-client"; return 1; }
    if have_systemd && ! systemctl is-active --quiet fail2ban; then
        echo "❌ Fail2ban 未运行（可尝试 systemctl restart fail2ban）"
        return 1
    fi
    fail2ban-client status sshd &>/dev/null || { echo "❌ sshd jail 未启用，请先菜单1"; return 1; }
    return 0
}

view_banned_ips() {
    ensure_fail2ban_ready || { pause; return; }
    echo "================ sshd 当前封禁 IP ================"
    if fail2ban-client get sshd banip &>/dev/null; then
        local ips; ips="$(fail2ban-client get sshd banip | tr -s ' ' | sed 's/^ *//;s/ *$//')"
        [[ -z "$ips" ]] && echo "✅ 当前无封禁 IP" || echo "$ips" | tr ' ' '\n'
    else
        fail2ban-client status sshd || true
    fi
    echo "=================================================="
    pause
}

unban_ip() {
    ensure_fail2ban_ready || { pause; return; }
    local ip=""
    read -rp "请输入要解禁的 IP（回车取消）: " ip
    [[ -z "$ip" ]] && { echo "已取消。"; pause; return; }
    [[ "$ip" =~ ^[0-9a-fA-F:./]+$ ]] || { echo "⚠ IP 格式不正确"; pause; return; }
    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        echo "✅ 已解禁：$ip"
    else
        echo "❌ 解禁失败：$ip"
    fi
    pause
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
    grep -Fxq "$ip" "$ALLOWLIST_FILE" 2>/dev/null && return 0
    echo "$ip" >> "$ALLOWLIST_FILE"
    sort -u "$ALLOWLIST_FILE" -o "$ALLOWLIST_FILE" || true
    return 0
}

allowlist_del_ip() {
    local ip="$1"
    ensure_allowlist_storage
    grep -Fxq "$ip" "$ALLOWLIST_FILE" 2>/dev/null || return 1
    grep -Fxv "$ip" "$ALLOWLIST_FILE" > "${ALLOWLIST_FILE}.tmp" && mv "${ALLOWLIST_FILE}.tmp" "$ALLOWLIST_FILE"
    return 0
}

sync_current_ssh_ip_to_allowlist() {
    ensure_allowlist_storage
    local cur=""
    cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
    [[ -n "$cur" ]] && allowlist_add_ip "$cur" >/dev/null 2>&1 || true
}

allowlist_show() {
    ensure_allowlist_storage
    echo "================ SSH 白名单列表 ================"
    [[ ! -s "$ALLOWLIST_FILE" ]] && echo "（当前为空）" || nl -ba "$ALLOWLIST_FILE"
    echo "==============================================="
}

read_ssh_port_override() {
    [[ -f "$SSH_PORT_OVERRIDE_FILE" ]] || return 1
    local v; v="$(tr -d '[:space:]' <"$SSH_PORT_OVERRIDE_FILE" 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=65535 )) && { echo "$v"; return 0; }
    return 1
}

write_ssh_port_override() { ensure_allowlist_storage; echo "$1" >"$SSH_PORT_OVERRIDE_FILE"; chmod 600 "$SSH_PORT_OVERRIDE_FILE" || true; }
clear_ssh_port_override() { rm -f "$SSH_PORT_OVERRIDE_FILE" >/dev/null 2>&1 || true; }

get_effective_ssh_port() {
    local ov=""; ov="$(read_ssh_port_override 2>/dev/null || true)"
    [[ -n "$ov" ]] && { echo "$ov"; return 0; }

    local sp=""; sp="$(get_current_session_ssh_port 2>/dev/null || true)"
    [[ -n "$sp" ]] && { echo "$sp"; return 0; }

    if command -v sshd >/dev/null 2>&1; then
        local p; p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | head -n1 || true)"
        [[ -n "$p" ]] && { echo "$p"; return 0; }
    fi

    if command -v ss >/dev/null 2>&1; then
        local p2
        p2="$(ss -lntp 2>/dev/null | awk '/sshd/ && $1~/^LISTEN/ {n=split($4,a,":"); port=a[n]; if(port~/^[0-9]+$/) print port}' | sort -n | uniq | head -n1 || true)"
        [[ -n "$p2" ]] && { echo "$p2"; return 0; }
    fi

    local p4=""
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        p4="$(get_sshd_value port)"
        [[ -n "$p4" && "$p4" =~ ^[0-9]+$ ]] && { echo "$p4"; return 0; }
    fi

    echo "22"
}

#-----------------------------
# 运行时规则下发：firewalld / nftables / iptables
#-----------------------------
apply_allowlist_rules_iptables() {
    local port="$1"
    ensure_allowlist_storage
    command -v iptables >/dev/null 2>&1 || return 1

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
    return 0
}

remove_allowlist_rules_iptables() {
    local port="$1"
    command -v iptables >/dev/null 2>&1 && {
        iptables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        iptables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        iptables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    }
    command -v ip6tables >/dev/null 2>&1 && {
        ip6tables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
        ip6tables -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    }
    return 0
}

apply_allowlist_rules_nftables() {
    local port="$1"
    ensure_allowlist_storage
    command -v nft >/dev/null 2>&1 || return 1

    nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    nft add table "$NFT_FAMILY" "$NFT_TABLE"
    nft add chain "$NFT_FAMILY" "$NFT_TABLE" input "{ type filter hook input priority -50; policy accept; }"
    nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ct state established,related accept

    local v4_set="" v6_set=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == *:* ]]; then v6_set+="${ip},"; else v4_set+="${ip},"; fi
    done < "$ALLOWLIST_FILE"
    v4_set="${v4_set%,}"; v6_set="${v6_set%,}"

    [[ -n "$v4_set" ]] && nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ip saddr "{ $v4_set }" tcp dport "$port" accept
    [[ -n "$v6_set" ]] && nft add rule "$NFT_FAMILY" "$NFT_TABLE" input ip6 saddr "{ $v6_set }" tcp dport "$port" accept

    nft add rule "$NFT_FAMILY" "$NFT_TABLE" input tcp dport "$port" drop
    return 0
}

remove_allowlist_rules_nftables() {
    command -v nft >/dev/null 2>&1 && nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    return 0
}

apply_allowlist_rules_firewalld() {
    local port="$1"
    ensure_allowlist_storage
    command -v firewall-cmd >/dev/null 2>&1 || return 1

    firewall-cmd --state >/dev/null 2>&1 || return 1

    firewall-cmd --permanent --delete-ipset="$FIREWALLD_IPSET" >/dev/null 2>&1 || true
    firewall-cmd --permanent --new-ipset="$FIREWALLD_IPSET" --type=hash:ip >/dev/null 2>&1 || true

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        firewall-cmd --permanent --ipset="$FIREWALLD_IPSET" --add-entry="$ip" >/dev/null 2>&1 || true
    done < "$ALLOWLIST_FILE"

    local rule_allow="rule source ipset=\"$FIREWALLD_IPSET\" port port=\"$port\" protocol=\"tcp\" accept"
    local rule_drop="rule port port=\"$port\" protocol=\"tcp\" drop"
    firewall-cmd --permanent --remove-rich-rule="$rule_allow" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-rich-rule="$rule_drop"  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-rich-rule="$rule_allow"
    firewall-cmd --permanent --add-rich-rule="$rule_drop"

    firewall-cmd --reload >/dev/null 2>&1 || firewall-cmd --complete-reload >/dev/null 2>&1 || true
    return 0
}

remove_allowlist_rules_firewalld() {
    local port="$1"
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    local rule_allow="rule source ipset=\"$FIREWALLD_IPSET\" port port=\"$port\" protocol=\"tcp\" accept"
    local rule_drop="rule port port=\"$port\" protocol=\"tcp\" drop"
    firewall-cmd --permanent --remove-rich-rule="$rule_allow" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-rich-rule="$rule_drop"  >/dev/null 2>&1 || true
    firewall-cmd --permanent --delete-ipset="$FIREWALLD_IPSET" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || firewall-cmd --complete-reload >/dev/null 2>&1 || true
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
# 兜底(B)：systemd 开机重放（强制可用）
#-----------------------------
ensure_systemd_fallback_unit() {
    have_systemd || return 1

    # 强制确保 /usr/local/bin/fb5 是新版本（支持 --apply-allowlist）
    if ! ensure_fb5_is_new; then
        echo "❌ fb5 命令不是新版本或不可用，无法创建 systemd 兜底。"
        return 1
    fi

    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=FB5 SSH Allowlist Enforcer (Boot Re-Apply)
After=network-online.target
Wants=network-online.target
After=firewalld.service nftables.service
Wants=firewalld.service nftables.service

[Service]
Type=oneshot
Environment=TERM=dumb
ExecStart=/usr/local/bin/fb5 --apply-allowlist
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
    systemctl enable --now fb5-ssh-allowlist >/dev/null 2>&1
    return 0
}

disable_systemd_fallback() {
    have_systemd || return 0
    systemctl disable --now fb5-ssh-allowlist >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

#-----------------------------
# 方案A：nftables 永久文件（尽力而为，不依赖它也能靠B）
#-----------------------------
build_nft_persist_file() {
    local port="$1"
    ensure_allowlist_storage
    mkdir -p "$NFT_PERSIST_DIR"

    local v4_items="" v6_items=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ "$ip" == *:* ]]; then v6_items+="${ip},"; else v4_items+="${ip},"; fi
    done < "$ALLOWLIST_FILE"
    v4_items="${v4_items%,}"; v6_items="${v6_items%,}"

    {
        echo "# Auto-generated by fb5 on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "flush table ${NFT_FAMILY} ${NFT_TABLE}"
        echo "table ${NFT_FAMILY} ${NFT_TABLE} {"
        echo "  chain input {"
        echo "    type filter hook input priority -50; policy accept;"
        echo "    ct state established,related accept"
        [[ -n "$v4_items" ]] && echo "    ip saddr { ${v4_items} } tcp dport ${port} accept"
        [[ -n "$v6_items" ]] && echo "    ip6 saddr { ${v6_items} } tcp dport ${port} accept"
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
    grep -qE 'include\s+".*/nftables\.d/\*\.nft"' "$NFT_MAIN_CONF" || echo 'include "/etc/nftables.d/*.nft"' >> "$NFT_MAIN_CONF"
    return 0
}

persist_allowlist_A_nftables() {
    local port="$1"
    command -v nft >/dev/null 2>&1 || return 1
    build_nft_persist_file "$port"
    ensure_nft_main_conf_include || return 1
    have_systemd || return 1
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables >/dev/null 2>&1 || nft -f "$NFT_MAIN_CONF" >/dev/null 2>&1 || return 1
    return 0
}

persist_allowlist_A() {
    local port="$1"
    detect_firewall
    case "$FIREWALL" in
        firewalld) return 0 ;; # firewalld permanent 本身可持久化
        nftables)  persist_allowlist_A_nftables "$port" ;;
        *) return 0 ;;         # iptables 持久化依赖较多，这里不强制
    esac
}

remove_persist_A() {
    detect_firewall
    case "$FIREWALL" in
        firewalld) return 0 ;;
        nftables)
            rm -f "$NFT_PERSIST_FILE" >/dev/null 2>&1 || true
            have_systemd && systemctl restart nftables >/dev/null 2>&1 || true
            ;;
        *) return 0 ;;
    esac
    return 0
}

#-----------------------------
# 立即应用：运行时 + A尽力 + B强制启用（保证重启恢复）
#-----------------------------
apply_allowlist_immediately_or_disable_if_empty() {
    local port="$1"

    sync_current_ssh_ip_to_allowlist

    if [[ ! -s "$ALLOWLIST_FILE" ]]; then
        echo "⚠ 白名单为空，自动关闭白名单限制以避免阻断全部 SSH。"
        remove_allowlist_rules "$port" || true
        remove_persist_A || true
        disable_systemd_fallback || true
        disable_allowlist_flag
        return 0
    fi

    apply_allowlist_rules "$port" || { echo "❌ 运行时规则应用失败。"; return 1; }
    enable_allowlist_flag

    if persist_allowlist_A "$port"; then
        echo "✅ 持久化(A)已写入（尽力而为）。"
    else
        echo "⚠ 持久化(A)未确认成功（不影响最终效果，将由兜底(B)保证重启恢复）。"
    fi

    # 关键：只要启用白名单，就必须启用(B)
    if have_systemd; then
        enable_systemd_fallback || {
            echo "❌ 兜底(B)启用失败：请检查 /usr/local/bin/fb5 是否为新版本且可执行。"
            return 1
        }
        echo "✅ 兜底(B)已启用：重启后会自动重新下发白名单规则。"
    else
        echo "⚠ 系统无 systemd，无法启用兜底(B)。重启持久化仅依赖(A)。"
    fi

    return 0
}

#-----------------------------
# 白名单菜单
#-----------------------------
ssh_allowlist_menu() {
    detect_firewall
    ensure_allowlist_storage
    sync_current_ssh_ip_to_allowlist

    local port; port="$(get_effective_ssh_port)"

    while true; do
        safe_clear
        echo "==============================================="
        echo " SSH 连接白名单（只允许白名单 IP 连接 SSH）"
        echo " 防火墙类型: $FIREWALL"
        echo " SSH 端口(当前生效): $port"
        echo " 白名单文件: $ALLOWLIST_FILE"
        echo "==============================================="
        echo " 1) 查看当前白名单（自动同步当前 SSH 来源 IP）"
        echo " 2) 追加添加 IP（立刻生效）"
        echo " 3) 删除白名单 IP（立刻生效；若删空自动关闭限制）"
        echo " 4) 关闭白名单限制（移除规则；保留列表文件）"
        echo " 0) 返回主菜单"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-4]: " C

        case "$C" in
            1)
                sync_current_ssh_ip_to_allowlist
                allowlist_show
                pause
                ;;
            2)
                local ip=""
                read -rp "请输入要允许 SSH 连接的 IP（如 1.1.1.1；回车取消）: " ip
                [[ -z "$ip" ]] && { echo "已取消。"; pause; continue; }
                is_valid_ip_or_cidr "$ip" || { echo "⚠ IP 格式不正确：$ip"; pause; continue; }

                allowlist_add_ip "$ip" || { echo "❌ 加入失败：$ip"; pause; continue; }
                sync_current_ssh_ip_to_allowlist

                local cur=""; cur="$(get_current_ssh_client_ip 2>/dev/null || true)"
                [[ -n "$cur" ]] && echo "🧾 当前 SSH 来源 IP：$cur（已确保在白名单中）" || echo "ℹ️ 未检测到 SSH 来源 IP（可能控制台执行）。"

                echo ""
                echo "⚠ 将立即应用白名单规则：除白名单 IP 外，其他 IP 将无法建立新的 SSH 连接。"
                read -rp "确认继续吗？[y/N]: " ok
                [[ "$ok" =~ ^[yY]$ ]] || { echo "已取消应用（白名单列表已更新）。"; pause; continue; }

                port="$(get_effective_ssh_port)"
                if apply_allowlist_immediately_or_disable_if_empty "$port"; then
                    echo "✅ 已应用白名单（并启用重启兜底）。"
                else
                    echo "❌ 应用失败。"
                fi
                pause
                ;;
            3)
                sync_current_ssh_ip_to_allowlist
                allowlist_show
                echo ""
                local dip=""
                read -rp "请输入要删除的 IP（需与列表完全一致；回车取消）: " dip
                [[ -z "$dip" ]] && { echo "已取消。"; pause; continue; }

                local cur2=""; cur2="$(get_current_ssh_client_ip 2>/dev/null || true)"
                if [[ -n "$cur2" && "$dip" == "$cur2" ]]; then
                    echo "⚠ 你正在删除当前 SSH 来源 IP：$cur2（可能导致断开后无法重连）"
                    read -rp "仍要继续删除并立即生效吗？[y/N]: " risk
                    [[ "$risk" =~ ^[yY]$ ]] || { echo "已取消。"; pause; continue; }
                fi

                allowlist_del_ip "$dip" || { echo "⚠ 白名单中不存在：$dip"; pause; continue; }

                port="$(get_effective_ssh_port)"
                apply_allowlist_immediately_or_disable_if_empty "$port" || true
                echo "✅ 已更新并立即生效。"
                pause
                ;;
            4)
                echo "⚠ 即将关闭 SSH 白名单限制（不删除白名单列表文件）。"
                read -rp "确认继续吗？[y/N]: " ok2
                [[ "$ok2" =~ ^[yY]$ ]] || { echo "已取消。"; pause; continue; }

                port="$(get_effective_ssh_port)"
                remove_allowlist_rules "$port" || true
                remove_persist_A || true
                disable_systemd_fallback || true
                disable_allowlist_flag
                echo "✅ 已关闭白名单限制（运行时/持久化/兜底已清理）。"
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
    fix_pkg_mgr || true

    echo "🧩 系统类型: $OS"
    echo "🛡 防火墙: $FIREWALL"
    echo "📦 包管理器: $(detect_pkg_mgr)"
    echo ""

    local SSH_PORT=""; SSH_PORT="$(prompt_ssh_port)"

    echo "📦 检查 Fail2ban 是否已安装..."
    if ! command -v fail2ban-client &>/dev/null; then
        echo "📦 安装 Fail2ban..."
        local PM; PM="$(detect_pkg_mgr)"
        if [[ "$PM" == "apt" ]]; then
            install_pkgs fail2ban
        else
            install_pkgs epel-release >/dev/null 2>&1 || true
            install_pkgs fail2ban fail2ban-firewalld || install_pkgs fail2ban
        fi
    fi

    mkdir -p /etc/fail2ban
    if [[ ! -f "$JAIL" ]]; then
        local MYIP="127.0.0.1"
        local TMPIP=""; TMPIP=$(curl -s --max-time 5 https://api.ipify.org || true)
        [[ -n "$TMPIP" ]] && MYIP="$TMPIP"
        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime  = 12h
findtime = 6h
maxretry = 3
EOF
    fi

    local CUR_SSH_IP=""; CUR_SSH_IP="$(get_current_ssh_client_ip 2>/dev/null || true)"
    if [[ -n "$CUR_SSH_IP" ]]; then
        add_ip_to_ignoreip "$CUR_SSH_IP" || true
        ensure_allowlist_storage
        allowlist_add_ip "$CUR_SSH_IP" >/dev/null 2>&1 || true
    fi

    local ACTION; ACTION="$(get_action_for_firewall)"
    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME
    CUR_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="3"
    CUR_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="21600"
    CUR_BANTIME="$(get_sshd_value bantime)";  [[ -z "$CUR_BANTIME"  ]] && CUR_BANTIME="12h"
    local LOGPATH; LOGPATH="$(pick_ssh_logpath)"

    rewrite_or_append_sshd_block "$SSH_PORT" "$ACTION" "$LOGPATH" "$CUR_MAXRETRY" "$CUR_FINDTIME" "$CUR_BANTIME"

    systemctl restart fail2ban || { echo "❌ Fail2ban 启动失败，请检查 $JAIL 语法。"; pause; return; }
    systemctl enable fail2ban >/dev/null 2>&1 || true

    # 安装/修复 fb5 命令（确保新版本）
    ensure_fb5_is_new || true

    echo "✅ SSH 防爆破配置完成。"
    pause
}

#-----------------------------
# 状态总览
#-----------------------------
print_status_summary() {
    echo "---------------- 当前运行状态 ----------------"
    local fb_status="未知" fb_enabled="未知" sshd_jail="未知"
    if have_systemd; then
        systemctl is-active --quiet fail2ban && fb_status="运行中" || fb_status="未运行"
        systemctl is-enabled --quiet fail2ban 2>/dev/null && fb_enabled="是" || fb_enabled="否"
    fi
    if command -v fail2ban-client &>/dev/null && have_systemd && systemctl is-active --quiet fail2ban; then
        fail2ban-client status sshd &>/dev/null && sshd_jail="已启用" || sshd_jail="未启用"
    fi

    local show_port="—"
    if [[ -f "$JAIL" ]] && grep -q "^\[sshd\]" "$JAIL"; then
        show_port="$(get_sshd_value port)"; [[ -z "$show_port" ]] && show_port="—"
    fi

    local fb5_status="未安装"
    [[ -x "$INSTALL_CMD_PATH" ]] && fb5_status="已安装($INSTALL_CMD_PATH)"

    local allow_status="未启用"
    [[ -f "$ALLOWLIST_ENABLED_FLAG" ]] && allow_status="已启用"
    [[ ! -f "$ALLOWLIST_ENABLED_FLAG" && -s "$ALLOWLIST_FILE" ]] && allow_status="已配置(未启用)"

    local b_fallback="不可用"
    if have_systemd; then
        if [[ -f "$SYSTEMD_UNIT" ]]; then
            systemctl is-enabled --quiet fb5-ssh-allowlist 2>/dev/null && b_fallback="已启用" || b_fallback="已安装(未启用)"
        else
            b_fallback="未安装"
        fi
    fi

    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 端口(记录于 fail2ban): $show_port"
    echo "快捷命令: $fb5_status"
    echo "SSH 白名单: $allow_status"
    echo "白名单兜底(B): $b_fallback"
    echo "------------------------------------------------"
    echo ""
}

#-----------------------------
# 命令行非交互入口：systemd 调用
#-----------------------------
cli_apply_allowlist() {
    detect_firewall
    ensure_allowlist_storage
    sync_current_ssh_ip_to_allowlist

    # 仅当已启用白名单才重放
    [[ -f "$ALLOWLIST_ENABLED_FLAG" ]] || exit 0

    local port; port="$(get_effective_ssh_port)"

    # 若为空则自动关闭（安全）
    apply_allowlist_immediately_or_disable_if_empty "$port" >/dev/null 2>&1 || true
    exit 0
}

#-----------------------------
# 主菜单
#-----------------------------
main_menu() {
    while true; do
        safe_clear
        echo "==============================================="
        echo " Fail2ban SSH 防爆破 管理脚本"
        echo " Author: DadaGi 大大怪"
        echo "==============================================="
        print_status_summary
        echo " 1) 安装 / 配置 SSH 防爆破（自动加入当前 SSH IP）"
        echo " 5) 查看 sshd 封禁 IP 列表"
        echo " 6) 解禁指定 IP（sshd）"
        echo " 7) SSH 连接白名单（新增/删除立即生效，重启自动恢复）"
        echo " 0) 退出"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-7]: " CHOICE
        case "$CHOICE" in
            1) install_or_config_ssh ;;
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
