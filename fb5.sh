#!/usr/bin/env bash
# ============================================================
# Fail2ban SSH Protector 菜单版 (2025)
# Author: DadaGi（大大怪）
#
# 功能：
#   1) 安装 / 配置 Fail2ban 仅用于 SSH 防爆破（安装时输入 SSH 端口，回车默认 22）
#   2) 卸载本脚本相关配置（可选同时卸载 fail2ban）
#   3) 快捷修改 SSH 防爆破参数：
#        - maxretry（失败次数）
#        - bantime（封禁时长）
#        - findtime（检测周期 / 统计时间窗口）
#   4) 安装 / 更新快捷命令（fb5），一条命令直接打开本面板
#
# 默认策略（首次安装 / 无 [sshd] 参数时）：
#   - maxretry = 3
#   - findtime = 21600（6小时）
#   - bantime  = 12h
#
# 说明：
#   - 只对 [sshd] jail 动手
#   - 可反复执行：若已存在 [sshd]，会按当前选择的 SSH 端口 + 当前参数(如能读取)进行更新
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
        apt-get update
        apt-get install -y curl
    fi
}

get_action_for_firewall() {
    detect_firewall
    case "$FIREWALL" in
        nftables) echo "nftables-multiport" ;;
        firewalld) echo "firewallcmd-ipset" ;;
        *) echo "iptables-multiport" ;;
    esac
}

pick_ssh_logpath() {
    # 尽量选择存在的日志文件，避免 jail 启动时报 “log file not found”
    local paths=()
    [[ -f /var/log/auth.log ]] && paths+=("/var/log/auth.log")
    [[ -f /var/log/secure ]] && paths+=("/var/log/secure")

    if (( ${#paths[@]} == 0 )); then
        # 兜底：仍写两个常见路径（某些系统虽不存在文件但会后续生成）
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

get_sshd_value() {
    # 用法：get_sshd_value key
    # 从 [sshd] 段读取配置，如 port/maxretry/findtime/bantime/action/logpath
    local key="$1"
    awk -v k="$key" '
        BEGIN{in_sshd=0}
        /^\[sshd\]/{in_sshd=1; next}
        /^\[.*\]/{if(in_sshd){in_sshd=0}}
        in_sshd && $1==k {print $3}
    ' "$JAIL" 2>/dev/null | tail -n1
}

rewrite_or_append_sshd_block() {
    # 参数：port action logpath maxretry findtime bantime
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
# 状态总览：面板状态 / 开机启动 / jail 状态
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

    echo "面板状态: $fb_status"
    echo "开机启动: $fb_enabled"
    echo "SSH 防爆破 (sshd): $sshd_jail"
    echo "SSH 端口(记录于 fail2ban): $show_port"
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

    local SSH_PORT
    SSH_PORT="$(prompt_ssh_port)"

    echo "📦 检查并安装 Fail2ban..."

    if [[ $OS == "centos" ]]; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y fail2ban fail2ban-firewalld >/dev/null 2>&1 || yum install -y fail2ban -y
    else
        apt-get update
        apt-get install -y fail2ban
    fi

    echo "📁 确保 /etc/fail2ban 目录存在..."
    mkdir -p /etc/fail2ban

    # 创建 jail.local 基础配置（仅当文件不存在）
    if [[ ! -f "$JAIL" ]]; then
        echo "📄 创建新的 jail.local..."
        local MYIP="127.0.0.1"
        local TMPIP=""
        TMPIP=$(curl -s --max-time 5 https://api.ipify.org || true)
        [[ -n "$TMPIP" ]] && MYIP="$TMPIP"

        # ✅ 这里改成你要的默认：maxretry=3, findtime=6h, bantime=12h
        cat > "$JAIL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 $MYIP
bantime  = 12h
findtime = 6h
maxretry = 3
EOF
    fi

    local ACTION
    ACTION="$(get_action_for_firewall)"

    # ✅ 这里是 [sshd] 段的默认回退值（第一次安装/读取不到时真正生效）
    local CUR_MAXRETRY CUR_FINDTIME CUR_BANTIME
    CUR_MAXRETRY="$(get_sshd_value maxretry)"; [[ -z "$CUR_MAXRETRY" ]] && CUR_MAXRETRY="3"
    CUR_FINDTIME="$(get_sshd_value findtime)"; [[ -z "$CUR_FINDTIME" ]] && CUR_FINDTIME="21600"   # 6小时
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
    print_status_summary
    echo "📌 查看详细状态：fail2ban-client status sshd"
    echo ""
    pause
}

#-----------------------------
# 3. 卸载本脚本相关配置
#-----------------------------
uninstall_all() {
    echo "⚠ 此操作将删除："
    echo "   - /etc/fail2ban/jail.local（若存在，会直接删除整个文件）"
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

    echo "✅ Fail2ban 自定义配置文件已删除。"

    read -rp "是否同时卸载 fail2ban 软件包？[y/N]: " CONFIRM2
    case "$CONFIRM2" in
        y|Y)
            detect_os
            if [[ $OS == "centos" ]]; then
                yum remove -y fail2ban || true
            else
                apt-get purge -y fail2ban || true
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

    # 读取并保留 action/logpath
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
# 4. 安装 / 更新快捷命令（fb5）
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
    echo "   注意：fb5 下载的是 REMOTE_URL 指向的脚本内容，请确保仓库里也是最新版。"
    echo ""
    pause
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
        echo " 1) 安装 / 配置 SSH 防爆破（安装时输入 SSH 端口，回车默认 22）"
        echo " 2) 快捷修改 SSH 防爆破参数（失败次数 / 封禁时长 / 检测周期）"
        echo " 3) 卸载本脚本相关配置（可选卸载 fail2ban）"
        echo " 4) 安装 / 更新快捷命令（fb5，一键打开本面板）"
        echo " 0) 退出"
        echo "-----------------------------------------------"
        read -rp "请输入选项 [0-4]: " CHOICE
        case "$CHOICE" in
            1) install_or_config_ssh ;;
            2) modify_ssh_params ;;
            3) uninstall_all ;;
            4) install_update_shortcut ;;
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
