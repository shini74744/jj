#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector + Telegram 通知菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 功能：
#   1) 安装 / 配置 Fail2ban 仅用于 SSH 防爆破
#   2) 对接 Telegram 通知：
#        - IP 被封禁时推送告警（带节点名）
#        - SSH 登录成功时推送提醒（带节点名）
#   3) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#   4) 快捷修改 SSH 防爆破参数：
#        - maxretry（失败次数）
#        - bantime（封禁时长）
#        - findtime（检测周期 / 统计时间窗口）
#   5) 安装 / 更新快捷命令（fb5），一条命令直接打开本面板
#
# 说明：
#   - 只对 [sshd] jail 和 sshd-login 提醒 jail 动手
#   - 可反复执行，避免重复写 [sshd]
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
TELEGRAM_VARS="/etc/fail2ban/telegram-vars.conf"

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

load_telegram_vars() {
    if [[ -f "$TELEGRAM_VARS" ]]; then
        # shellcheck source=/etc/fail2ban/telegram-vars.conf
        source "$TELEGRAM_VARS"
    fi
}

save_telegram_vars() {
    mkdir -p "$(dirname "$TELEGRAM_VARS")"
    cat > "$TELEGRAM_VARS" <<EOF
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MACHINE_NAME="${MACHINE_NAME:-}"
EOF
}

#-----------------------------
# 状态总览：面板状态 / 开机启动 / jail 状态 / 节点名
#-----------------------------
print_status_summary() {
    echo "---------------- 当前运行状态 ----------------"
    local fb_status="未知"
    local fb_enabled="未知"
    local sshd_jail="未知"
    local sshlogin_jail="未知"

    # 读取节点名（如果配置过 TG）
    load_telegram_vars
    local node_name="${MACHINE_NAME:-未设置}"

    # Fail2ban 服务状态
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

    # jail 状态
    if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
        if fail2ban-client status sshd &>/dev/null; then
            sshd_jail="已启用"
        else
            sshd_jail="未启用"
        fi

        if fail2ban-client status sshd-login &>/dev/null; then
            sshlogin_jail="已启用"
        else
            sshlogin_jail="未启用"
        fi
    elif ! command -v fail2ban-client &>/dev/null; then
        sshd_jail="未知（未安装 Fail2ban）"
        sshlogin_jail="未知（未安装 Fail2ban）"
    else
        sshd_jail="未知（Fail2ban 未运行）"
        sshlogin_jail="未知（Fail2ban 未运行）"
    fi

    echo "节点名称: $node_name"
    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 登录提醒 (sshd-login): $sshlogin_jail"
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
    echo ""
    print_status_summary
    echo "📌 查看详细状态：fail2ban-client status sshd"
    echo ""
    pause
}

#-----------------------------
# 2. 对接 Telegram 通知（封禁 + 登录提醒 + 节点名）
#-----------------------------
setup_telegram() {
    ensure_curl

    if [[ ! -f "$JAIL" ]]; then
        echo "⚠ 未检测到 $JAIL，请先执行『1) 安装/配置 SSH 防爆破』"
        pause
        return
    fi

    load_telegram_vars

    echo "================ 对接 Telegram 通知 ================"
    echo "需要信息："
    echo "  - BOT_TOKEN：通过 BotFather 创建机器人得到"
    echo "  - CHAT_ID：你自己的 ID 或群组 ID"
    echo "  - 节点名称：给这台服务器起个昵称（例：香港1、日本-甲骨文1）"
    echo "----------------------------------------------------"
    echo "当前配置（如有）："
    echo "  当前 BOT_TOKEN : ${BOT_TOKEN:-未设置}"
    echo "  当前 CHAT_ID   : ${CHAT_ID:-未设置}"
    echo "  当前 节点名称  : ${MACHINE_NAME:-未设置}"
    echo "提示：回车留空 = 保留当前值（如果之前有）。"
    echo "===================================================="
    echo ""

    read -rp "请输入 BOT_TOKEN（回车保留当前）: " INPUT_TOKEN
    if [[ -n "$INPUT_TOKEN" ]]; then
        BOT_TOKEN="$INPUT_TOKEN"
    fi

    read -rp "请输入 CHAT_ID（回车保留当前）: " INPUT_CHAT
    if [[ -n "$INPUT_CHAT" ]]; then
        CHAT_ID="$INPUT_CHAT"
    fi

    read -rp "给这台服务器起个名字（例：香港1，回车保留当前/可留空）: " INPUT_NAME
    if [[ -n "$INPUT_NAME" ]]; then
        MACHINE_NAME="$INPUT_NAME"
    fi

    # 检查必要字段
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo "❌ BOT_TOKEN 或 CHAT_ID 为空，请至少设置一次。"
        pause
        return
    fi

    save_telegram_vars

    mkdir -p /etc/fail2ban/action.d
    mkdir -p /etc/fail2ban/filter.d
    mkdir -p /etc/fail2ban/jail.d

    # 2.1 封禁告警 action（带节点名）
    echo "📄 写入 /etc/fail2ban/action.d/telegram.conf ..."
    cat > /etc/fail2ban/action.d/telegram.conf <<EOF
[Definition]

actionstart = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🚀 *Fail2Ban 已启动*\\n节点: $MACHINE_NAME\\n主机: *<fq-hostname>*"

actionstop = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🛑 *Fail2Ban 已停止*\\n节点: $MACHINE_NAME\\n主机: *<fq-hostname>*"

actionban = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🚫 *Fail2Ban 封禁告警*\\n节点: $MACHINE_NAME\\nJail: *<name>*\\n攻击 IP: \`<ip>\`\\n主机: *<fq-hostname>*\\n时间: <time>"

actionunban = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=✅ *IP 解除封禁*\\n节点: $MACHINE_NAME\\nJail: *<name>*\\nIP: \`<ip>\`\\n主机: *<fq-hostname>*\\n时间: <time>"
EOF

    # 2.2 SSH 登录提醒 action（带节点名，只发消息，不封 IP）
    echo "📄 写入 /etc/fail2ban/action.d/telegram-ssh-login.conf ..."
    cat > /etc/fail2ban/action.d/telegram-ssh-login.conf <<EOF
[Definition]

actionban = curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=🔐 *SSH 登录提醒*\\n节点: $MACHINE_NAME\\n用户: <user>\\nIP: \`<ip>\`\\n主机: *<fq-hostname>*\\n时间: <time>"
EOF

    # 2.3 SSH 登录成功 filter（不再使用 %(__prefix_line)s，避免版本兼容问题）
    echo "📄 写入 /etc/fail2ban/filter.d/sshd-login.conf ..."
    cat > /etc/fail2ban/filter.d/sshd-login.conf <<'EOF'
[Definition]
# 匹配 sshd 登录成功日志行
# 示例：Nov 17 13:30:51 host sshd[12345]: Accepted password for root from 1.2.3.4 port 56789 ssh2
failregex = ^.*sshd\[[0-9]+\]: Accepted (password|publickey|keyboard-interactive/pam) for (?P<user>\S+) from <HOST> .*$

ignoreregex =
EOF

    # 2.4 SSH 登录提醒 jail（不封，只通知）
    echo "📄 写入 /etc/fail2ban/jail.d/sshd-login.local ..."
    cat > /etc/fail2ban/jail.d/sshd-login.local <<EOF
[sshd-login]
enabled  = true
filter   = sshd-login
backend  = auto
logpath  = /var/log/auth.log /var/log/secure
maxretry = 1
findtime = 60
bantime  = 1
action   = telegram-ssh-login
EOF

    # 2.5 更新 sshd jail，加上 telegram action（封禁时推送）
    echo "🛠 修改 [sshd] jail，加入 telegram 封禁告警..."

    ACTION=$(get_action_for_firewall)

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

    echo "🔄 重启 Fail2ban 以应用 Telegram 通知与 SSH 登录提醒..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 和 telegram*.conf / sshd-login.conf 语法。"
        pause
        return
    fi

    # 发送测试通知
    echo "📨 发送 Telegram 测试通知..."
    TEST_RESP=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=Fail2ban+Telegram+对接成功\\n节点: $MACHINE_NAME")

    if echo "$TEST_RESP" | grep -q '"ok":true'; then
        echo "✅ 测试通知已发送，请在 Telegram 中检查是否收到。"
    else
        echo "⚠ 测试通知发送失败，返回信息："
        echo "$TEST_RESP"
    fi

    echo ""
    print_status_summary
    echo "📌 之后："
    echo "   - IP 被 Fail2ban 封禁 → 会推送封禁告警（带节点名）"
    echo "   - 每次 SSH 登录成功 → 会推送登录提醒（带节点名）"
    echo "   - 再次执行本菜单，可修改 BOT_TOKEN / CHAT_ID / 节点名（以最后一次为准）"
    pause
}

#-----------------------------
# 4. 快捷修改 SSH 防爆破参数
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

    # 读取当前参数
    CURRENT_MAXRETRY=$(awk '
        BEGIN{in_sshd=0}
        /^\[sshd\]/{in_sshd=1; next}
        /^\[.*\]/{if(in_sshd){in_sshd=0}}
        in_sshd && $1=="maxretry" {print $3}
    ' "$JAIL" | tail -n1)

    CURRENT_BANTIME=$(awk '
        BEGIN{in_sshd=0}
        /^\[sshd\]/{in_sshd=1; next}
        /^\[.*\]/{if(in_sshd){in_sshd=0}}
        in_sshd && $1=="bantime" {print $3}
    ' "$JAIL" | tail -n1)

    CURRENT_FINDTIME=$(awk '
        BEGIN{in_sshd=0}
        /^\[sshd\]/{in_sshd=1; next}
        /^\[.*\]/{if(in_sshd){in_sshd=0}}
        in_sshd && $1=="findtime" {print $3}
    ' "$JAIL" | tail -n1)

    [[ -z "$CURRENT_MAXRETRY" ]] && CURRENT_MAXRETRY="（未设置，默认 5）"
    [[ -z "$CURRENT_BANTIME" ]] && CURRENT_BANTIME="（未设置，默认 12h）"
    [[ -z "$CURRENT_FINDTIME" ]] && CURRENT_FINDTIME="（未设置，默认 600 秒）"

    echo "================ 快捷修改 SSH 防爆破参数 ================"
    echo "当前 SSH 配置："
    echo "  maxretry（失败次数）   : $CURRENT_MAXRETRY"
    echo "  bantime（封禁时长）    : $CURRENT_BANTIME"
    echo "  findtime（检测周期 秒）: $CURRENT_FINDTIME"
    echo "---------------------------------------------------------"
    echo "留空则表示不修改该项。"
    echo "bantime 支持格式：600（秒）、12h、1d 等 Fail2ban 支持的时长格式。"
    echo "findtime 一般用秒数，比如 600 表示 10 分钟。"
    echo "========================================================="
    echo ""

    read -rp "请输入新的 maxretry（失败次数，例：5，留空不改）： " NEW_MAXRETRY
    read -rp "请输入新的 bantime（封禁时长，例：12h 或 3600，留空不改）： " NEW_BANTIME
    read -rp "请输入新的 findtime（检测周期秒数，例：600，留空不改）： " NEW_FINDTIME

    if [[ -z "$NEW_MAXRETRY" && -z "$NEW_BANTIME" && -z "$NEW_FINDTIME" ]]; then
        echo "ℹ️ 未输入任何修改，保持原样。"
        pause
        return
    fi

    # 修改 [sshd] 段中的 maxretry
    if [[ -n "$NEW_MAXRETRY" ]]; then
        if ! [[ "$NEW_MAXRETRY" =~ ^[0-9]+$ ]]; then
            echo "⚠ maxretry 必须是整数，已忽略该项修改。"
        else
            sed -i "/^\[sshd\]/,/^\[.*\]/{s/^maxretry[[:space:]]*=.*/maxretry = $NEW_MAXRETRY/}" "$JAIL"
            echo "✅ 已将 maxretry 修改为：$NEW_MAXRETRY"
        fi
    fi

    # 修改 [sshd] 段中的 bantime
    if [[ -n "$NEW_BANTIME" ]]; then
        sed -i "/^\[sshd\]/,/^\[.*\]/{s/^bantime[[:space:]]*=.*/bantime = $NEW_BANTIME/}" "$JAIL"
        echo "✅ 已将 bantime 修改为：$NEW_BANTIME"
    fi

    # 修改 [sshd] 段中的 findtime
    if [[ -n "$NEW_FINDTIME" ]]; then
        if ! [[ "$NEW_FINDTIME" =~ ^[0-9]+$ ]]; then
            echo "⚠ findtime 必须是整数秒数，已忽略该项修改。"
        else
            sed -i "/^\[sshd\]/,/^\[.*\]/{s/^findtime[[:space:]]*=.*/findtime = $NEW_FINDTIME/}" "$JAIL"
            echo "✅ 已将 findtime 修改为：$NEW_FINDTIME 秒"
        fi
    fi

    echo "🔄 重启 Fail2ban 以应用新参数..."
    if ! systemctl restart fail2ban; then
        echo "❌ Fail2ban 启动失败，请检查 $JAIL 是否有语法错误。"
        pause
        return
    fi

    echo ""
    echo "✅ 修改已生效！"
    print_status_summary
    echo "📌 当前 SSH jail 详细状态："
    if systemctl is-active --quiet fail2ban; then
        fail2ban-client status sshd || echo "  (fail2ban 已运行，但 sshd jail 查询失败)"
    else
        echo "  fail2ban 未运行，无法获取 sshd jail 状态。"
    fi
    echo ""
    pause
}

#-----------------------------
# 5. 安装 / 更新快捷命令（fb5）
#-----------------------------
install_update_shortcut() {
    ensure_curl
    echo "================ 安装 / 更新快捷命令 ================"
    echo "将本脚本从远程地址："
    echo "  $REMOTE_URL"
    echo "下载到固定位置："
    echo "  $INSTALL_CMD_PATH"
    echo "并赋予执行权限，之后可直接运行命令：fb5"
    echo "====================================================="
    echo ""
    read -rp "确认安装 / 更新快捷命令 fb5 吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *)   echo "已取消。"; pause; return ;;
    esac

    mkdir -p "$(dirname "$INSTALL_CMD_PATH")"

    if ! curl -fsSL "$REMOTE_URL" -o "$INSTALL_CMD_PATH"; then
        echo "❌ 下载失败，请检查网络或仓库地址。"
        pause
        return
    fi

    chmod +x "$INSTALL_CMD_PATH"

    echo ""
    echo "✅ 已安装 / 更新快捷命令：fb5"
    echo "👉 以后可以直接在任意目录运行：fb5"
    echo "   当前这次执行仍然是现有版本，下次运行 fb5 即加载新版本脚本。"
    echo ""
    pause
}

#-----------------------------
# 3. 卸载本脚本相关配置
#-----------------------------
uninstall_all() {
    echo "⚠ 此操作将删除："
    echo "   - /etc/fail2ban/jail.local"
    echo "   - /etc/fail2ban/jail.d/sshd-login.local"
    echo "   - /etc/fail2ban/action.d/telegram.conf"
    echo "   - /etc/fail2ban/action.d/telegram-ssh-login.conf"
    echo "   - /etc/fail2ban/filter.d/sshd-login.conf"
    echo "   - /etc/fail2ban/telegram-vars.conf"
    echo "   （不会删除系统自带的 jail.conf 等默认配置）"
    echo ""
    read -rp "是否同时删除快捷命令 $INSTALL_CMD_PATH ? [y/N]: " RM_CMD
    case "$RM_CMD" in
        y|Y)
            rm -f "$INSTALL_CMD_PATH"
            echo "✅ 已删除快捷命令：$INSTALL_CMD_PATH"
            ;;
        *)
            echo "已保留快捷命令（如存在）。"
            ;;
    esac

    read -rp "确认继续删除上述 Fail2ban 配置吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *)   echo "已取消卸载配置。"; pause; return ;;
    esac

    systemctl stop fail2ban 2>/dev/null || true

    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/jail.d/sshd-login.local
    rm -f /etc/fail2ban/action.d/telegram.conf
    rm -f /etc/fail2ban/action.d/telegram-ssh-login.conf
    rm -f /etc/fail2ban/filter.d/sshd-login.conf
    rm -f "$TELEGRAM_VARS"

    echo "✅ Fail2ban 相关自定义配置文件已删除。"

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
        print_status_summary
        echo " 1) 安装 / 配置 SSH 防爆破"
        echo " 2) 对接 TG 通知（封禁+SSH 登录提醒 + 节点名）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 4) 快捷修改 SSH 防爆破参数（失败次数 / 封禁时长 / 检测周期）"
        echo " 5) 安装 / 更新快捷命令（fb5，一键打开本面板）"
        echo " 0) 退出"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-5]: " CHOICE
        case "$CHOICE" in
            1) install_or_config_ssh ;;
            2) setup_telegram ;;
            3) uninstall_all ;;
            4) modify_ssh_params ;;
            5) install_update_shortcut ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "❌ 无效选项。"; pause ;;
        esac
    done
}

#-----------------------------
# 脚本入口
#-----------------------------
ensure_root
main_menu
