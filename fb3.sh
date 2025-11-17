#!/usr/bin/env bash
# ============================================================
# Modern Fail2ban + X-UI Login Protection (2025 Final Edition)
# Author: DadaGi（大大怪）
# ============================================================

set -e

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 权限运行此脚本"
    exit 1
fi

echo "==============================================="
echo "🔰 Modern Fail2ban Installer + X-UI Protector"
echo "🔰 Author: DadaGi 大大怪"
echo "==============================================="

# -------------------------------
#  Detect Operating System
# -------------------------------
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
    elif grep -qi "ubuntu" /etc/os-release; then
        OS="ubuntu"
    elif grep -qi "debian" /etc/os-release; then
        OS="debian"
    else
        echo "❌ 不支持的操作系统"
        exit 1
    fi
}
detect_os

# -------------------------------
#  Detect Firewall
# -------------------------------
detect_firewall() {
    if command -v firewall-cmd &>/dev/null; then
        FIREWALL="firewalld"
    elif command -v nft &>/dev/null; then
        FIREWALL="nftables"
    else
        FIREWALL="iptables"
    fi
}
detect_firewall

echo "🧩 系统类型: $OS"
echo "🛡 防火墙: $FIREWALL"
echo ""

# -------------------------------
#  Install Fail2ban
# -------------------------------
echo "📦 正在安装 Fail2ban..."

if [[ $OS == "centos" ]]; then
    yum install -y epel-release
    yum install -y fail2ban fail2ban-firewalld || yum install -y fail2ban
elif [[ $OS == "ubuntu" || $OS == "debian" ]]; then
    apt update -y
    apt install -y fail2ban
fi

# -------------------------------
#  Ensure Configuration Directory Exists
# -------------------------------
echo "📁 检查 Fail2ban 配置目录..."
mkdir -p /etc/fail2ban
sleep 0.5

JAIL="/etc/fail2ban/jail.local"

# -------------------------------
#  Create jail.local if missing
# -------------------------------
if [[ ! -f "$JAIL" ]]; then
    echo "📄 创建新的 jail.local..."
    cat > $JAIL <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $(curl -s https://api.ipify.org || echo "127.0.0.1")
bantime = 12h
findtime = 30m
maxretry = 5
EOF
fi

# -------------------------------
# Ensure sshd section is not duplicated
# -------------------------------
if ! grep -q "^\[sshd\]" "$JAIL"; then
cat >> $JAIL <<EOF

[sshd]
enabled = true
port = ssh
filter = sshd
action = $( [[ $FIREWALL == "nftables" ]] && echo "nftables-multiport" || ([[ $FIREWALL == "firewalld" ]] && echo "firewallcmd-ipset" || echo "iptables-multiport") )
logpath = /var/log/auth.log /var/log/secure
EOF
fi

# Determine action for X-UI
if [[ $FIREWALL == "nftables" ]]; then
    ACTION="nftables-multiport"
elif [[ $FIREWALL == "firewalld" ]]; then
    ACTION="firewallcmd-ipset"
else
    ACTION="iptables-multiport"
fi

# -------------------------------
#  X-UI Login Protection
# -------------------------------
XUILOG="/usr/local/x-ui/x-ui.log"

if [[ -f "$XUILOG" ]]; then
    echo "🛡 检测到 X-UI 日志: $XUILOG"
    echo "🛡 自动启用 X-UI 防爆破"

    # Create filter
    mkdir -p /etc/fail2ban/filter.d
    cat > /etc/fail2ban/filter.d/xui-login.conf <<'EOF'
[Definition]
failregex = ^.*WARNING - wrong username:.*IP: "<HOST>".*$
ignoreregex =
EOF

    # Append jail config if not present
    if ! grep -q "^\[xui-login\]" "$JAIL"; then
cat >> $JAIL <<EOF

[xui-login]
enabled = true
filter = xui-login
logpath = $XUILOG
backend = auto
maxretry = 5
findtime = 600
bantime = 12h
action = $ACTION
EOF
    fi
else
    echo "⚠ 未找到 X-UI 日志: $XUILOG"
    echo "⚠ 跳过 X-UI 防爆破配置"
fi

# -------------------------------
#  Restart Fail2ban
# -------------------------------
echo "🔄 重启 Fail2ban..."
systemctl restart fail2ban || {
    echo "❌ Fail2ban 启动失败，请检查 jail.local 是否重复或有格式错误"
    exit 1
}
systemctl enable fail2ban

echo ""
echo "==============================================="
echo "✅ Fail2ban + X-UI 防爆破 已成功启用！"
echo "🛡 SSH 已防护"
[[ -f "$XUILOG" ]] && echo "🛡 X-UI 登录已防护"
echo "🧱 防火墙: $FIREWALL"
echo "📁 配置文件: /etc/fail2ban/jail.local"
echo "📄 过滤器: /etc/fail2ban/filter.d/xui-login.conf"
echo ""
echo "📌 查看状态: fail2ban-client status"
[[ -f "$XUILOG" ]] && echo "📌 查看 X-UI 保护状态: fail2ban-client status xui-login"
echo "==============================================="
