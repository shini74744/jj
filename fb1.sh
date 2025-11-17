#!/usr/bin/env bash
# ============================================
# Modern Fail2ban Auto Installer (2025)
# Author: DadaGi 大大怪
# ============================================

set -e

# Detect root
if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 权限运行此脚本"
    exit 1
fi

echo "============================================"
echo " Modern Fail2ban Installer (2025)"
echo " Author: DadaGi 大大怪"
echo "============================================"

# Detect OS
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

# Detect firewall (iptables / firewalld / nftables)
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
echo "🛡 防火墙类型: $FIREWALL"
echo ""

# Install fail2ban
echo "📦 开始安装 fail2ban ..."
if [[ $OS == "centos" ]]; then
    yum install -y epel-release
    yum install -y fail2ban fail2ban-firewalld || yum install -y fail2ban
elif [[ $OS == "ubuntu" || $OS == "debian" ]]; then
    apt-get update -y
    apt-get install -y fail2ban
fi

# User IP (auto whitelist)
MYIP=$(curl -s https://api.ipify.org || echo "127.0.0.1")

# Create jail.local (do not overwrite existing file)
JAIL=/etc/fail2ban/jail.local
if [[ ! -f "$JAIL" ]]; then
    echo "🔧 创建 fail2ban 配置文件 ..."
    cat > $JAIL <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime = 12h
findtime = 30m
maxretry = 5

# 通用 action（自动根据防火墙选择）
EOF
fi

# Append firewall action
case $FIREWALL in
firewalld)
    ACTION="action = firewallcmd-ipset"
    ;;
nftables)
    ACTION="action = nftables-multiport"
    ;;
iptables)
    ACTION="action = iptables-multiport"
    ;;
esac

# Add SSH protection
cat >> $JAIL <<EOF

[sshd]
enabled = true
port = ssh
filter = sshd
$ACTION
logpath = /var/log/auth.log /var/log/secure
EOF

# Detect Nginx log
if [[ -d /var/log/nginx ]]; then
cat >> $JAIL <<EOF

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
$ACTION
logpath = /var/log/nginx/error.log
EOF
fi

# For x-ui panel (optional, if installed)
if [[ -f /usr/local/x-ui/x-ui.log ]]; then
cat >> $JAIL <<EOF

[xui-login]
enabled = true
filter = xui-login
priority = 1
$ACTION
logpath = /usr/local/x-ui/x-ui.log
maxretry = 5
EOF
fi

echo "🔄 重启 fail2ban ..."
systemctl restart fail2ban
systemctl enable fail2ban

echo ""
echo "============================================"
echo "✅ Fail2ban 安装完成！"
echo "🛡 自动防护已启用：SSH (必定), Nginx (若存在), x-ui (若存在)"
echo "🧱 防火墙模式：$FIREWALL"
echo "👤 你的 IP 已加入白名单：$MYIP"
echo "📌 查看状态命令： fail2ban-client status"
echo "📌 查看某个 jail： fail2ban-client status sshd"
echo "============================================"
