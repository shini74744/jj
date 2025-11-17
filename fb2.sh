#!/usr/bin/env bash
# ============================================================
# Modern Fail2ban + X-UI Login Protection (2025)
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
#  Detect Firewall System
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
#  Detect User IP for Whitelist
# -------------------------------
MYIP=$(curl -s https://api.ipify.org || echo "127.0.0.1")

# -------------------------------
#  Create jail.local (if not exists)
# -------------------------------
JAIL="/etc/fail2ban/jail.local"

if [[ ! -f "$JAIL" ]]; then
cat > $JAIL <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime = 12h
findtime = 30m
maxretry = 5
EOF
fi

# Choose fail2ban action according to firewall
case $FIREWALL in
firewalld)
    ACTION="firewallcmd-ipset"
    ;;
nftables)
    ACTION="nftables-multiport"
    ;;
iptables)
    ACTION="iptables-multiport"
    ;;
esac

# -------------------------------
#  Add SSH Protection (guaranteed)
# -------------------------------
cat >> $JAIL <<EOF

[sshd]
enabled = true
port = ssh
filter = sshd
action = $ACTION
logpath = /var/log/auth.log /var/log/secure
EOF

# -------------------------------
#  X-UI Login Protection
#  Log path confirmed: /usr/local/x-ui/x-ui.log
# -------------------------------
XUILOG="/usr/local/x-ui/x-ui.log"

if [[ -f "$XUILOG" ]]; then

echo "🛡 检测到 X-UI 登录日志：$XUILOG"
echo "🛡 已自动启用 Fail2ban X-UI 防爆破"

# Create filter
cat > /etc/fail2ban/filter.d/xui-login.conf <<'EOF'
[Definition]
failregex = ^.*WARNING - wrong username:.*IP: "<HOST>".*$
ignoreregex =
EOF

# Add jail config
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

else
    echo "⚠ 未找到 /usr/local/x-ui/x-ui.log ，跳过 X-UI 防爆破配置"
fi

# -------------------------------
#  Restart Fail2ban
# -------------------------------
systemctl restart fail2ban
systemctl enable fail2ban

echo ""
echo "==============================================="
echo "✅ Fail2ban + X-UI 防爆破 已成功启用！"
echo "🛡 SSH 已保护"
[[ -f "$XUILOG" ]] && echo "🛡 X-UI 登录已防护"
echo "🧱 防火墙类型：$FIREWALL"
echo "👤 你的 IP 已自动列入白名单：$MYIP"
echo ""
echo "📌 查看全部状态： fail2ban-client status"
[[ -f "$XUILOG" ]] && echo "📌 查看 X-UI 保护状态： fail2ban-client status xui-login"
echo "==============================================="
