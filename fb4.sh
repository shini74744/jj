#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector + Telegram 通知菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 功能：
#   1) 安装 / 配置 Fail2ban 仅用于 SSH 防爆破
#   2) 对接 Telegram 通知（封禁时推送告警）
#   3) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#
# 说明：
#   - 只对 [sshd] jail 动手，不改动其他服务
#   - 可反复执行，避免重复写 [sshd]
#   - Telegram 部分自动生成 action.d/telegram.conf
# ============================================================

set -e

#-----------------------------
# 公共变量
#-----------------------------
OS=""
FIREWALL=""
JAIL="/etc/fail2ban/jail.local"

#-----------------------------
# 工具函数
#-----------------------------
pause() {
    read -rp "按 Enter 返回菜单..." _
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "❌ 请使用 root 权限运行此脚本"
        exit 1
    fi
}

detect_os() {
    if [[ -n "$OS" ]]; then return; fi
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

ensure_curl() {
    if command -v curl &>/dev/null; then
        return
    fi
    detect_os
    echo "📦 未检测到 curl，正在安装..."
    if [[ $OS == "centos" ]]; then
        yum install -y curl
    else
        apt update -y
        apt install -y curl
    fi
}

get_action_for_firewall() {
    detect_firewall
    case "$FIREWALL" in
        nftables)
            echo "nftables-multiport"
            ;;
        firewalld)
            echo "firewallcmd-ipset"
            ;;
        *)
            echo "iptables-multiport"
            ;;
    esac
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
    echo ""

    echo "📦 检查并安装 Fail2ban..."

    if [[ $OS == "centos" ]]; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y fail2ban fail2ban-firewalld >/dev/null 2>&1 || yum install -y fail2ban -y
    else
        apt update -y
        apt install -y fail2ban
    fi

    echo "📁 确保 /etc/fail2ban 目录存在..."
    mkdir -p /etc/fail2ban

    # 创建 jail.local 基础配置
    if [[ ! -f "$JAIL" ]]; then
        echo "📄 创建新的 jail.local..."
        MYIP="127.0.0.1"
        if command -v curl &>/dev/null; then
            TMPIP=$(curl -s https://api.ipify.org || true)
            [[ -n "$TMPIP" ]] && MYIP="$TMPIP"
        fi

        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime  = 12h
findtime = 30m
maxretry = 5
EOF
    fi

    ACTION=$(get_action_for_firewall)

    # 配置 sshd jail，避免重复添加
    if grep -q "^\[sshd\]" "$JAIL"; then
        echo "ℹ️ 检测到 jail.local 已存在 [sshd] 配置，不重复写入。"
    else
        echo "🛡 写入 SSH 防爆破配置到 jail.local..."

        cat >> "$JAIL" <<EOF

[sshd]
enabled  = true
port     = ssh
filter   = sshd
action   = $ACTION
logpath  = /var/log/auth.log /var/log/secure
maxretry = 5
findtime = 600
bantime  = 12h
EOF
    fi

    echo "🔄 重启 Fail2ban..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 是否有语法错误。"
        pause
        return
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true

    echo ""
    echo "✅ SSH 防爆破配置完成！"
    echo "📌 查看状态：fail2ban-client status sshd"
    echo ""
    pause
}

#-----------------------------
# 2. 对接 Telegram 通知
#-----------------------------
setup_telegram() {
    ensure_curl

    if [[ ! -f "$JAIL" ]]; then
        echo "⚠ 未检测到 $JAIL，请先执行『1) 安装/配置 SSH 防爆破』"
        pause
        return
    fi

    echo "================ 对接 Telegram 通知 ================"
    echo "提示：需要先在 Telegram 用 BotFather 创建机器人"
    echo "再获取：BOT_TOKEN 和 CHAT_ID（你的个人或群组 ID）"
    echo "===================================================="
    echo ""

    read -rp "请输入 BOT_TOKEN（形如 123456:ABCDEF...）: " BOT_TOKEN
    read -rp "请输入 CHAT_ID（纯数字）: " CHAT_ID

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo "❌ BOT_TOKEN 或 CHAT_ID 不能为空"
        pause
        return
    fi

    # 写入 Telegram action 配置
    echo "📄 写入 /etc/fail2ban/action.d/telegram.conf ..."
    mkdir -p /etc/fail2ban/action.d

    cat > /etc/fail2ban/action.d/telegram.conf <<EOF
[Definition]

actionstart = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🚀 Fail2Ban 已启动于 *<fq-hostname>*"

actionstop = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🛑 Fail2Ban 已停止于 *<fq-hostname>*"

actionban = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🚫 *Fail2Ban 封禁告警*\nJail: *<name>*\nIP: \`<ip>\`\n主机: *<fq-hostname>*\n时间: <time>"

actionunban = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=✅ IP 解除封禁\nJail: *<name>*\nIP: \`<ip>\`\n主机: *<fq-hostname>*\n时间: <time>"
EOF

    # 更新 sshd jail，将 telegram action 加进去
    echo "🛠 修改 [sshd] jail，加入 telegram 动作..."

    ACTION=$(get_action_for_firewall)

    # 如果没有 [sshd]，顺便创建一个带 telegram 的
    if ! grep -q "^\[sshd\]" "$JAIL"; then
        cat >> "$JAIL" <<EOF

[sshd]
enabled  = true
port     = ssh
filter   = sshd
action   = $ACTION
           telegram
logpath  = /var/log/auth.log /var/log/secure
maxretry = 5
findtime = 600
bantime  = 12h
EOF
    else
        # 重写 [sshd] 段，统一为带 telegram 的版本
        tmpfile="$(mktemp)"
        awk -v act="$ACTION" '
            BEGIN{in_sshd=0; printed=0}
            /^\[sshd\]/{
                if (!printed) {
                    print "[sshd]"
                    print "enabled  = true"
                    print "port     = ssh"
                    print "filter   = sshd"
                    print "action   = " act
                    print "           telegram"
                    print "logpath  = /var/log/auth.log /var/log/secure"
                    print "maxretry = 5"
                    print "findtime = 600"
                    print "bantime  = 12h"
                    printed=1
                }
                in_sshd=1
                next
            }
            /^\[.*\]/{ in_sshd=0 }
            { if(!in_sshd) print }
        ' "$JAIL" > "$tmpfile" && mv "$tmpfile" "$JAIL"
    fi

    echo "🔄 重启 Fail2ban 以应用 Telegram 通知..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 和 telegram.conf 语法。"
        pause
        return
    fi

    # 发送测试通知
    echo "📨 发送 Telegram 测试通知..."
    TEST_RESP=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=Fail2ban+Telegram+通知对接测试")

    if echo "$TEST_RESP" | grep -q '"ok":true'; then
        echo "✅ 测试通知已发送，请在 Telegram 中检查是否收到。"
    else
        echo "⚠ 测试通知发送失败，返回信息："
        echo "$TEST_RESP"
    fi

    echo ""
    echo "📌 之后只要有 IP 被 Fail2ban 封禁，都会收到 Telegram 告警。"
    pause
}

#-----------------------------
# 3. 卸载本脚本相关配置
#-----------------------------
uninstall_all() {
    echo "⚠ 此操作将删除："
    echo "   - /etc/fail2ban/jail.local"
    echo "   - /etc/fail2ban/action.d/telegram.conf"
    echo "   （不会删除系统自带的 jail.conf 等默认配置）"
    echo ""
    read -rp "确认继续删除这些配置吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y)
            ;;
        *)
            echo "已取消卸载。"
            pause
            return
            ;;
    esac

    systemctl stop fail2ban 2>/dev/null || true

    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/action.d/telegram.conf

    echo "✅ 配置文件已删除。"

    read -rp "是否同时卸载 fail2ban 软件包？[y/N]: " CONFIRM2
    case "$CONFIRM2" in
        y|Y)
            detect_os
            if [[ $OS == "centos" ]]; then
                yum remove -y fail2ban || true
            else
                apt purge -y fail2ban || true
            fi
            systemctl disable fail2ban 2>/dev/null || true
            echo "✅ fail2ban 软件包已卸载。"
            ;;
        *)
            echo "已保留 fail2ban 软件包（但已无自定义配置）。"
            ;;
    esac

    pause
}

#-----------------------------
# 主菜单
#-----------------------------
main_menu() {
    while true; do
        clear
        echo "==============================================="
        echo " Fail2ban SSH 防爆破 + Telegram 通知 管理脚本"
        echo " Author: DadaGi 大大怪"
        echo "==============================================="
        echo " 1) 安装 / 配置 SSH 防爆破"
        echo " 2) 对接 TG 通知（BOT 封禁推送）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 0) 退出"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-3]: " CHOICE
        case "$CHOICE" in
            1)
                install_or_config_ssh
                ;;
            2)
                setup_telegram
                ;;
            3)
                uninstall_all
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "❌ 无效选项。"
                pause
                ;;
        esac
    done
}

#-----------------------------
# 脚本入口
#-----------------------------
ensure_root
main_menu
