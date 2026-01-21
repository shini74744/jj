#!/usr/bin/env bash
set -euo pipefail

# =============================
# SSH 白名单管理（菜单版）
# - 自动安装 nftables/iptables（优先 nftables）
# - 自动把当前 SSH 客户端 IP 加入白名单
# - 添加/删除 IP 后立即生效
# - 持久化：systemd（优先）/ rc.local（回退）
# - 快捷命令：sship
# - 初始化强制覆盖历史配置
# =============================

APP_NAME="ssh-whitelist"
INSTALL_PATH="/usr/local/sbin/ssh_whitelist_manager.sh"
BIN_LINK="/usr/local/bin/sship"

CONFIG_DIR="/etc/ssh-whitelist"
WL_FILE="$CONFIG_DIR/whitelist.cidr"
PORT_FILE="$CONFIG_DIR/ssh_port"
BACKEND_FILE="$CONFIG_DIR/backend"

UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
RC_LOCAL="/etc/rc.local"

NFT_TABLE="inet ssh_whitelist"
NFT_CHAIN="input_ssh_whitelist"

IPT_CHAIN="SSH_WHITELIST"

log() { echo "[$APP_NAME] $*"; }
err() { echo "[$APP_NAME][ERROR] $*" >&2; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "请用 root 运行：sudo $0"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if has_cmd apt-get; then echo "apt"
  elif has_cmd dnf; then echo "dnf"
  elif has_cmd yum; then echo "yum"
  elif has_cmd zypper; then echo "zypper"
  else echo "unknown"
  fi
}

install_packages() {
  local pkgs=("$@")
  local pm
  pm="$(detect_pkg_mgr)"

  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive in "${pkgs[@]}"
      ;;
    *)
      err "无法识别包管理器，请手动安装：${pkgs[*]}"
      return 1
      ;;
  esac
}

ensure_backend_installed() {
  if has_cmd nft || has_cmd iptables; then
    return 0
  fi

  log "未检测到 nft 或 iptables，开始自动安装（优先 nftables）..."
  if install_packages nftables; then
    log "已安装 nftables。"
  else
    log "安装 nftables 失败，尝试安装 iptables..."
    install_packages iptables
  fi

  if ! has_cmd nft && ! has_cmd iptables; then
    err "自动安装失败：仍未找到 nft/iptables"
    exit 1
  fi
}

choose_backend() {
  if has_cmd nft; then echo "nft"
  else echo "iptables"
  fi
}

get_current_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $1}' <<<"$SSH_CONNECTION"
  else
    echo ""
  fi
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  touch "$WL_FILE"
  chmod 600 "$WL_FILE"
}

backup_rules() {
  mkdir -p /var/backups/ssh-whitelist >/dev/null 2>&1 || true
  if has_cmd nft; then
    nft list ruleset > /var/backups/ssh-whitelist/nft.ruleset.$(date +%F_%H%M%S).bak 2>/dev/null || true
  fi
  if has_cmd iptables-save; then
    iptables-save > /var/backups/ssh-whitelist/iptables.v4.$(date +%F_%H%M%S).bak 2>/dev/null || true
  fi
}

# --------------------------
# IP / CIDR 处理：允许输入单独 IP 或 CIDR
# --------------------------
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }

is_valid_cidr_basic() {
  local s="$1"
  # IPv4/CIDR
  if [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
    return 0
  fi
  # IPv6/CIDR
  if [[ "$s" =~ ^[0-9a-fA-F:]+/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$ ]]; then
    return 0
  fi
  return 1
}

normalize_ip_or_cidr() {
  # 输入：ip 或 cidr；输出：cidr
  local raw="$1"
  raw="${raw// /}"

  if [[ -z "$raw" ]]; then
    echo ""
    return 1
  fi

  if [[ "$raw" == */* ]]; then
    if is_valid_cidr_basic "$raw"; then
      echo "$raw"
      return 0
    fi
    echo ""
    return 1
  fi

  # 单独 IP：自动补掩码
  if is_ipv4 "$raw"; then
    echo "${raw}/32"
    return 0
  fi
  if is_ipv6 "$raw"; then
    echo "${raw}/128"
    return 0
  fi

  echo ""
  return 1
}

# --------------------------
# 配置加载
# --------------------------
load_config_or_die() {
  if [[ ! -f "$PORT_FILE" || ! -f "$WL_FILE" || ! -f "$BACKEND_FILE" ]]; then
    err "未找到配置。请先选择菜单 1 进行初始化配置。"
    exit 1
  fi
}

read_port() { cat "$PORT_FILE"; }

validate_whitelist_nonempty() {
  if [[ ! -f "$WL_FILE" ]]; then
    err "白名单文件不存在：$WL_FILE"
    exit 1
  fi
  if ! grep -vE '^\s*#|^\s*$' "$WL_FILE" >/dev/null 2>&1; then
    err "白名单为空：$WL_FILE（至少需要 1 条 CIDR）"
    exit 1
  fi
}

# --------------------------
# 应用规则：nftables
# --------------------------
nft_apply_rules() {
  local ssh_port="$1"
  validate_whitelist_nonempty
  backup_rules

  nft add table inet ssh_whitelist 2>/dev/null || true
  nft 'add chain inet ssh_whitelist input_ssh_whitelist { type filter hook input priority -150; policy accept; }' 2>/dev/null || true
  nft flush chain inet ssh_whitelist input_ssh_whitelist

  nft add rule inet ssh_whitelist input_ssh_whitelist ct state established,related accept
  nft add rule inet ssh_whitelist input_ssh_whitelist iif lo accept

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local cidr
    cidr="$(awk '{print $1}' <<<"$line")"
    [[ -z "$cidr" ]] && continue

    if [[ "$cidr" == *:* ]]; then
      nft add rule inet ssh_whitelist input_ssh_whitelist ip6 saddr "$cidr" tcp dport "$ssh_port" accept
    else
      nft add rule inet ssh_whitelist input_ssh_whitelist ip saddr "$cidr" tcp dport "$ssh_port" accept
    fi
  done < "$WL_FILE"

  nft add rule inet ssh_whitelist input_ssh_whitelist tcp dport "$ssh_port" reject with tcp reset
}

nft_clear_rules() { has_cmd nft && nft delete table inet ssh_whitelist 2>/dev/null || true; }

# --------------------------
# 应用规则：iptables（仅 IPv4）
# --------------------------
iptables_apply_rules() {
  local ssh_port="$1"
  validate_whitelist_nonempty
  backup_rules

  iptables -N "$IPT_CHAIN" 2>/dev/null || true
  iptables -F "$IPT_CHAIN"

  iptables -A "$IPT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "$IPT_CHAIN" -i lo -j ACCEPT

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local cidr
    cidr="$(awk '{print $1}' <<<"$line")"
    [[ -z "$cidr" ]] && continue

    if [[ "$cidr" == *:* ]]; then
      log "提示：iptables 不处理 IPv6 白名单：$cidr（如需 IPv6 请使用 nftables）"
      continue
    fi
    iptables -A "$IPT_CHAIN" -p tcp -s "$cidr" --dport "$ssh_port" -j ACCEPT
  done < "$WL_FILE"

  iptables -A "$IPT_CHAIN" -p tcp --dport "$ssh_port" -j REJECT --reject-with tcp-reset

  if ! iptables -C INPUT -p tcp --dport "$ssh_port" -j "$IPT_CHAIN" >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport "$ssh_port" -j "$IPT_CHAIN"
  fi
}

iptables_clear_rules() {
  if ! has_cmd iptables; then return 0; fi
  local ssh_port="22"
  if [[ -f "$PORT_FILE" ]]; then
    ssh_port="$(cat "$PORT_FILE" 2>/dev/null || echo 22)"
  fi

  while iptables -C INPUT -p tcp --dport "$ssh_port" -j "$IPT_CHAIN" >/dev/null 2>&1; do
    iptables -D INPUT -p tcp --dport "$ssh_port" -j "$IPT_CHAIN" || true
  done
  iptables -F "$IPT_CHAIN" 2>/dev/null || true
  iptables -X "$IPT_CHAIN" 2>/dev/null || true
}

apply_rules_now() {
  load_config_or_die
  local ssh_port backend
  ssh_port="$(read_port)"
  backend="$(cat "$BACKEND_FILE")"

  if [[ "$backend" == "nft" ]]; then
    nft_apply_rules "$ssh_port"
  else
    iptables_apply_rules "$ssh_port"
  fi
  log "规则已应用：backend=$backend, SSH_PORT=$ssh_port"
}

# --------------------------
# 持久化 + 快捷命令 sship
# --------------------------
install_self_and_shortcut() {
  # 强制覆盖安装路径
  if [[ "$0" != "$INSTALL_PATH" ]]; then
    cp -f "$0" "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
  fi

  # 快捷命令：/usr/local/bin/sship
  cat > "$BIN_LINK" <<EOF
#!/usr/bin/env bash
exec sudo ${INSTALL_PATH}
EOF
  chmod 755 "$BIN_LINK"
}

ensure_persistence() {
  install_self_and_shortcut

  if has_cmd systemctl; then
    cat > "/etc/systemd/system/${APP_NAME}.service" <<EOF
[Unit]
Description=SSH Whitelist Apply Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}.service" >/dev/null 2>&1 || systemctl enable --now "${APP_NAME}.service"
    log "已启用开机自启（systemd）：${APP_NAME}.service"
  else
    if [[ ! -f "$RC_LOCAL" ]]; then
      cat > "$RC_LOCAL" <<'EOF'
#!/bin/sh -e
exit 0
EOF
      chmod +x "$RC_LOCAL"
    fi
    if ! grep -q "${INSTALL_PATH} --apply" "$RC_LOCAL"; then
      sed -i "s#^exit 0#${INSTALL_PATH} --apply\nexit 0#" "$RC_LOCAL"
    fi
    log "已配置开机自启（rc.local）：$RC_LOCAL"
  fi
}

remove_persistence() {
  if has_cmd systemctl; then
    systemctl disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_NAME}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if [[ -f "$RC_LOCAL" ]]; then
    sed -i "\#${INSTALL_PATH} --apply#d" "$RC_LOCAL" 2>/dev/null || true
  fi

  rm -f "$BIN_LINK" 2>/dev/null || true
}

# --------------------------
# 强制覆盖旧配置（初始化时调用）
# --------------------------
wipe_all_existing_config_silent() {
  # 清理规则（尽力）
  nft_clear_rules || true
  iptables_clear_rules || true

  # 清理持久化
  remove_persistence || true

  # 清理配置目录
  rm -rf "$CONFIG_DIR" 2>/dev/null || true
}

# --------------------------
# 菜单动作
# --------------------------
action_init_config_force_overwrite() {
  ensure_backend_installed

  # 检测旧配置并强制覆盖
  if [[ -d "$CONFIG_DIR" || -f "$UNIT_FILE" || -f "$INSTALL_PATH" || -f "$BIN_LINK" ]]; then
    log "检测到历史配置/脚本，开始强制覆盖重建..."
    wipe_all_existing_config_silent
  fi

  ensure_dirs

  echo
  echo "开始配置 SSH 白名单（将覆盖历史配置）："
  echo -n "请输入 SSH 登录端口（回车默认 22）："
  read -r input_port || true
  local ssh_port="22"
  if [[ -n "${input_port:-}" ]]; then
    if [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
      ssh_port="$input_port"
    else
      err "端口不合法，使用默认 22"
      ssh_port="22"
    fi
  fi
  echo "$ssh_port" > "$PORT_FILE"
  chmod 600 "$PORT_FILE"

  local backend
  backend="$(choose_backend)"
  echo "$backend" > "$BACKEND_FILE"
  chmod 600 "$BACKEND_FILE"

  # 自动加入当前 SSH 客户端 IP（若能获取）
  local client_ip cidr
  client_ip="$(get_current_ssh_client_ip)"
  if [[ -n "$client_ip" ]]; then
    if [[ "$client_ip" == *:* ]]; then cidr="${client_ip}/128"; else cidr="${client_ip}/32"; fi
    if ! grep -Fxq "$cidr" "$WL_FILE" 2>/dev/null; then
      echo "$cidr" >> "$WL_FILE"
      log "已将当前 SSH 客户端 IP 加入白名单：$cidr"
    else
      log "当前 SSH 客户端 IP 已在白名单中：$cidr"
    fi
  else
    log "未检测到 SSH_CONNECTION，无法自动获取当前客户端 IP（控制台执行属正常）。"
  fi

  # 若白名单为空，要求用户补充（但不强制中断：给出提示并返回菜单）
  if ! grep -vE '^\s*#|^\s*$' "$WL_FILE" >/dev/null 2>&1; then
    err "白名单为空。请使用菜单 2 添加至少 1 条（例如：1.2.3.4 或 1.2.3.4/32）。"
    ensure_persistence
    return 0
  fi

  apply_rules_now
  ensure_persistence

  echo
  log "初始化完成。之后可直接输入：sship 打开菜单。"
  log "建议立刻用白名单 IP 从另一台机器测试新的 SSH 连接。"
}

action_add_remove_menu() {
  load_config_or_die

  while true; do
    echo
    echo "追加/删除白名单："
    echo "  1) 添加 IP 或 CIDR（如 1.2.3.4 或 1.2.3.4/32 或 10.0.0.0/8）"
    echo "  2) 删除 CIDR（需与文件中一致；单独 IP 会自动按 /32 或 /128 匹配）"
    echo "  3) 查看当前白名单"
    echo "  0) 返回上级菜单"
    echo -n "请选择："
    read -r sub || true

    case "${sub:-}" in
      1)
        echo -n "请输入要添加的 IP 或 CIDR："
        read -r raw || true
        local cidr
        cidr="$(normalize_ip_or_cidr "$raw")" || true
        if [[ -z "$cidr" ]]; then
          err "输入不合法：$raw"
          continue
        fi
        if grep -Fxq "$cidr" "$WL_FILE" 2>/dev/null; then
          log "已存在：$cidr"
        else
          echo "$cidr" >> "$WL_FILE"
          log "已添加：$cidr"
        fi
        apply_rules_now
        ;;
      2)
        echo -n "请输入要删除的 IP 或 CIDR："
        read -r raw || true
        local cidr
        cidr="$(normalize_ip_or_cidr "$raw")" || true
        if [[ -z "$cidr" ]]; then
          err "输入不合法：$raw"
          continue
        fi
        if grep -Fxq "$cidr" "$WL_FILE" 2>/dev/null; then
          grep -Fxv "$cidr" "$WL_FILE" > "${WL_FILE}.tmp"
          mv -f "${WL_FILE}.tmp" "$WL_FILE"
          chmod 600 "$WL_FILE"
          log "已删除：$cidr"

          # 防止删空导致锁死：至少保留一条
          if ! grep -vE '^\s*#|^\s*$' "$WL_FILE" >/dev/null 2>&1; then
            err "白名单被删空。为避免锁死，已撤销本次删除（请至少保留 1 条）。"
            echo "$cidr" >> "$WL_FILE"
          fi
        else
          log "未找到：$cidr"
        fi
        apply_rules_now
        ;;
      3)
        echo
        echo "当前白名单（$WL_FILE）："
        nl -ba "$WL_FILE" || true
        ;;
      0) return 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

action_remove_all() {
  echo
  echo "该操作将："
  echo " - 清理 SSH 白名单规则"
  echo " - 移除开机自启"
  echo " - 删除配置目录：$CONFIG_DIR"
  echo " - 删除快捷命令：$BIN_LINK"
  echo " - 删除脚本：$INSTALL_PATH（以及当前脚本本身）"
  echo
  echo -n "确认删除全部配置？输入 YES 继续："
  read -r confirm || true
  if [[ "${confirm:-}" != "YES" ]]; then
    log "已取消。"
    return 0
  fi

  nft_clear_rules || true
  iptables_clear_rules || true
  remove_persistence || true
  rm -rf "$CONFIG_DIR"
  rm -f "$INSTALL_PATH" 2>/dev/null || true

  local self="$0"
  if [[ -f "$self" ]]; then
    rm -f "$self" 2>/dev/null || true
  fi

  log "已全部删除完成。"
}

show_status() {
  if [[ -f "$PORT_FILE" ]]; then echo "SSH 端口：$(cat "$PORT_FILE")"; else echo "SSH 端口：未配置"; fi
  if [[ -f "$BACKEND_FILE" ]]; then echo "后端：$(cat "$BACKEND_FILE")"; else echo "后端：未配置"; fi
  if [[ -f "$WL_FILE" ]]; then
    echo "白名单文件：$WL_FILE"
    echo "白名单条目："
    nl -ba "$WL_FILE" || true
  else
    echo "白名单文件：未配置"
  fi

  echo "快捷命令：$( [[ -f "$BIN_LINK" ]] && echo "已安装（sship）" || echo "未安装" )"

  if has_cmd systemctl; then
    echo
    echo "systemd 自启状态："
    systemctl is-enabled "${APP_NAME}.service" >/dev/null 2>&1 && echo "enabled" || echo "disabled"
    systemctl is-active "${APP_NAME}.service" >/dev/null 2>&1 && echo "active" || echo "inactive"
  fi
}

# --------------------------
# 非交互模式（给开机自启用）
# --------------------------
if [[ "${1:-}" == "--apply" ]]; then
  need_root
  load_config_or_die
  apply_rules_now
  exit 0
fi

# --------------------------
# 主菜单
# --------------------------
main_menu() {
  need_root

  while true; do
    echo
    echo "=============================="
    echo " SSH 登录白名单管理（菜单）"
    echo "=============================="
    echo "  1) 开始配置白名单（初始化/强制覆盖）"
    echo "  2) 追加/删除 IP 白名单（立即生效）"
    echo "  3) 删除配置（全部删除：规则+持久化+脚本）"
    echo "  4) 查看状态"
    echo "  0) 退出"
    echo -n "请选择："
    read -r choice || true

    case "${choice:-}" in
      1) action_init_config_force_overwrite ;;
      2) action_add_remove_menu ;;
      3) action_remove_all; exit 0 ;;
      4) show_status ;;
      0) exit 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

main_menu
