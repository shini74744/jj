#!/usr/bin/env bash
# Time Sync Manager
# Supported: Ubuntu / Debian (systemd)
# Priority: systemd-timesyncd (NTP/UDP 123)
# Fallback: HTTPS Date header (TCP 443)
# Schedule: on boot + every 4 hours

set -Eeuo pipefail

VERSION="1.2.1"
SELF_PATH="/usr/local/sbin/time-sync-manager"
SOURCE_URL="https://raw.githubusercontent.com/shini74744/jj/refs/heads/main/ntp.sh"
CONFIG_FILE="/etc/time-sync-manager.conf"
SERVICE_FILE="/etc/systemd/system/time-sync-manager.service"
TIMER_FILE="/etc/systemd/system/time-sync-manager.timer"
LOG_TAG="time-sync-manager"
DEFAULT_TIMEZONE="Asia/Hong_Kong"
NTP_WAIT_SECONDS=45
MAX_HTTPS_SOURCE_SPREAD=5

C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_RESET='\033[0m'

# systemd/journal and redirected output should stay free of ANSI escape codes.
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

info() { printf '%b\n' "${C_CYAN}[信息]${C_RESET} $*"; }
ok()   { printf '%b\n' "${C_GREEN}[成功]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[提示]${C_RESET} $*"; }
err()  { printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 用户运行，或执行：sudo bash $0"
        exit 1
    fi
}

check_supported_system() {
    [[ -r /etc/os-release ]] || { err "无法识别操作系统"; return 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            err "当前系统为 ${PRETTY_NAME:-${ID:-unknown}}，本脚本仅支持 Ubuntu 和 Debian"
            return 1
            ;;
    esac
    command -v apt-get >/dev/null 2>&1 || { err "系统缺少 apt-get"; return 1; }
    command -v systemctl >/dev/null 2>&1 || { err "系统缺少 systemd"; return 1; }
    [[ -d /run/systemd/system ]] || { err "当前系统未以 systemd 启动"; return 1; }
}

check_time_daemon_conflicts() {
    local pkg
    for pkg in chrony ntp ntpsec openntpd; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
            err "检测到已安装的时间服务：$pkg"
            err "为避免替换现有配置，本脚本停止安装。请先人工决定保留哪个时间服务。"
            return 1
        fi
    done
}

install_dependencies() {
    info "检查 Ubuntu/Debian 所需组件……"
    export DEBIAN_FRONTEND=noninteractive
    local -a required=(systemd-timesyncd curl ca-certificates python3 iso-codes tzdata util-linux)
    local -a missing=()
    local pkg
    for pkg in "${required[@]}"; do
        if ! dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        ok "所需组件均已安装，跳过 apt 更新"
        return 0
    fi

    info "缺少组件：${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
}

ntp_synced() {
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]
}

ntp_udp_reachable() {
    python3 - <<'PY'
import socket, time

hosts = (
    "ntp.ubuntu.com",
    "time.cloudflare.com",
    "time.google.com",
    "pool.ntp.org",
)
packet = b"\x1b" + 47 * b"\0"
deadline = time.monotonic() + 12

for host in hosts:
    if time.monotonic() >= deadline:
        break
    try:
        addresses = socket.getaddrinfo(host, 123, socket.AF_UNSPEC, socket.SOCK_DGRAM)
    except OSError:
        continue
    # One IPv4 and one IPv6 address per provider is sufficient for reachability.
    tested_families = set()
    for family, socktype, proto, _, address in addresses:
        if family in tested_families or time.monotonic() >= deadline:
            continue
        tested_families.add(family)
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.settimeout(min(1.5, max(0.1, deadline - time.monotonic())))
        try:
            sock.sendto(packet, address)
            data, _ = sock.recvfrom(512)
            if len(data) >= 48:
                raise SystemExit(0)
        except OSError:
            pass
        finally:
            sock.close()
raise SystemExit(1)
PY
}

source_script_path() {
    local source_path temp_source
    source_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)

    if [[ -n "$source_path" && -f "$source_path" &&
          "$source_path" != */bash && "$source_path" != /dev/fd/* &&
          "$source_path" != /proc/self/fd/* && "$source_path" != /proc/[0-9]*/fd/* ]]; then
        printf '%s\n' "$source_path"
        return 0
    fi

    # bash <(curl ...) and curl ... | bash have no durable source file.
    # Fetch the canonical GitHub Raw copy again, then verify syntax and identity.
    info "检测到管道/进程替换运行，正在从官方 Raw 地址获取可安装副本……" >&2
    temp_source=$(mktemp /tmp/time-sync-manager.download.XXXXXX)
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "$SOURCE_URL" -o "$temp_source"; then
        rm -f "$temp_source"
        err "从 GitHub 下载安装副本失败：$SOURCE_URL"
        return 1
    fi

    if ! bash -n "$temp_source"; then
        rm -f "$temp_source"
        err "下载的脚本未通过 Bash 语法检查，拒绝安装"
        return 1
    fi
    if ! grep -q '^# Time Sync Manager$' "$temp_source" ||
       ! grep -q '^SELF_PATH="/usr/local/sbin/time-sync-manager"$' "$temp_source"; then
        rm -f "$temp_source"
        err "下载内容不是预期的时间同步管理器，拒绝安装"
        return 1
    fi

    chmod 0600 "$temp_source"
    printf '%s\n' "$temp_source"
}

timezone_tools_ready() {
    command -v python3 >/dev/null 2>&1 &&
    [[ -r /usr/share/zoneinfo/zone.tab ]] &&
    { [[ -r /usr/share/iso-codes/json/iso_3166-1.json ]] ||
      [[ -r /usr/share/iso-codes/json/iso_3166.json ]]; }
}

valid_timezone_name() {
    local tz=$1
    [[ "$tz" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)+$ ]] &&
    [[ "$tz" != /* && "$tz" != *"/../"* && "$tz" != ../* && "$tz" != */.. ]] &&
    [[ -e "/usr/share/zoneinfo/$tz" ]]
}

get_configured_timezone() {
    local tz=""
    if [[ -r "$CONFIG_FILE" ]]; then
        tz=$(sed -n 's/^TIMEZONE=//p' "$CONFIG_FILE" | head -n1)
    fi
    if [[ -z "$tz" ]]; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    fi
    valid_timezone_name "$tz" || tz="$DEFAULT_TIMEZONE"
    printf '%s\n' "$tz"
}

save_timezone() {
    local tz=$1 tmp
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
    chmod 0644 "$tmp"
    printf 'TIMEZONE=%s\n' "$tz" >"$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# Resolve timezone query. Supported inputs:
# - IANA timezone: Asia/Hong_Kong
# - Chinese aliases: 香港、台湾、日本、韩国、美国等
# - Abbreviations/country codes: hk, tw, jp, kr, us
# - English country name: France, United Kingdom
# - City/timezone fragment: London, Berlin, New_York
resolve_timezones() {
    local query=$1
    python3 - "$query" <<'PY'
import gettext, json, os, re, sys
q = sys.argv[1].strip()
if not q:
    raise SystemExit(0)

zone_root = "/usr/share/zoneinfo"
zone_tab = "/usr/share/zoneinfo/zone.tab"

aliases = {
    "香港":"HK", "港澳":"HK", "hk":"HK", "hongkong":"HK", "hong kong":"HK",
    "台湾":"TW", "台灣":"TW", "台北":"TW", "tw":"TW", "taiwan":"TW", "taipei":"TW",
    "中国":"CN", "中國":"CN", "大陆":"CN", "大陸":"CN", "内地":"CN", "內地":"CN", "cn":"CN", "china":"CN",
    "日本":"JP", "jp":"JP", "japan":"JP", "东京":"JP", "東京":"JP",
    "韩国":"KR", "韓國":"KR", "南韩":"KR", "南韓":"KR", "kr":"KR", "korea":"KR",
    "新加坡":"SG", "sg":"SG", "singapore":"SG",
    "马来西亚":"MY", "馬來西亞":"MY", "大马":"MY", "大馬":"MY", "my":"MY", "malaysia":"MY",
    "泰国":"TH", "泰國":"TH", "th":"TH", "thailand":"TH",
    "越南":"VN", "vn":"VN", "vietnam":"VN",
    "菲律宾":"PH", "菲律賓":"PH", "ph":"PH", "philippines":"PH",
    "印度尼西亚":"ID", "印度尼西亞":"ID", "印尼":"ID", "id":"ID", "indonesia":"ID",
    "印度":"IN", "in":"IN", "india":"IN",
    "澳大利亚":"AU", "澳大利亞":"AU", "澳洲":"AU", "au":"AU", "australia":"AU",
    "新西兰":"NZ", "新西蘭":"NZ", "nz":"NZ", "new zealand":"NZ",
    "美国":"US", "美國":"US", "美帝":"US", "us":"US", "usa":"US", "united states":"US",
    "加拿大":"CA", "ca":"CA", "canada":"CA",
    "英国":"GB", "英國":"GB", "uk":"GB", "gb":"GB", "united kingdom":"GB", "britain":"GB",
    "法国":"FR", "法國":"FR", "fr":"FR", "france":"FR",
    "德国":"DE", "德國":"DE", "de":"DE", "germany":"DE",
    "荷兰":"NL", "荷蘭":"NL", "nl":"NL", "netherlands":"NL",
    "瑞士":"CH", "ch":"CH", "switzerland":"CH",
    "意大利":"IT", "義大利":"IT", "it":"IT", "italy":"IT",
    "西班牙":"ES", "es":"ES", "spain":"ES",
    "葡萄牙":"PT", "pt":"PT", "portugal":"PT",
    "俄罗斯":"RU", "俄羅斯":"RU", "俄国":"RU", "俄國":"RU", "ru":"RU", "russia":"RU",
    "乌克兰":"UA", "烏克蘭":"UA", "ua":"UA", "ukraine":"UA",
    "巴西":"BR", "br":"BR", "brazil":"BR",
    "墨西哥":"MX", "mx":"MX", "mexico":"MX",
    "阿根廷":"AR", "ar":"AR", "argentina":"AR",
    "南非":"ZA", "za":"ZA", "south africa":"ZA",
    "阿联酋":"AE", "阿聯酋":"AE", "迪拜":"AE", "杜拜":"AE", "ae":"AE", "uae":"AE",
    "土耳其":"TR", "tr":"TR", "turkey":"TR", "türkiye":"TR",
    "以色列":"IL", "il":"IL", "israel":"IL",
    "沙特":"SA", "沙特阿拉伯":"SA", "sa":"SA", "saudi arabia":"SA",
}

# Exact IANA timezone first. Reject traversal-like values even if a filesystem
# path happens to exist below /usr/share/zoneinfo.
iana = q.replace(" ", "_")
if ("/" in iana and ".." not in iana.split("/") and
        not iana.startswith("/") and
        re.fullmatch(r"[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)+", iana) and
        os.path.exists(os.path.join(zone_root, iana))):
    print(iana)
    raise SystemExit

countries = {}
iso_rows = []
iso_paths = [
    "/usr/share/iso-codes/json/iso_3166-1.json",
    "/usr/share/iso-codes/json/iso_3166.json",
]
for path in iso_paths:
    try:
        data = json.load(open(path, encoding="utf-8"))
        iso_rows = data.get("3166-1", data.get("3166", []))
        for row in iso_rows:
            code = row.get("alpha_2", "").upper()
            for key in ("name", "official_name", "common_name"):
                name = row.get(key)
                if code and name:
                    countries[name.casefold()] = code
        break
    except Exception:
        pass

# iso-codes ships gettext catalogs for many languages. Load Simplified and
# Traditional Chinese catalogs so country names beyond the hand-written aliases
# (e.g. 挪威、冰岛、肯尼亚) are also recognized.
for locale in ("zh_CN", "zh_TW", "zh_HK"):
    for domain in ("iso_3166-1", "iso_3166"):
        try:
            trans = gettext.translation(domain, "/usr/share/locale", [locale])
        except Exception:
            continue
        for row in iso_rows:
            code = row.get("alpha_2", "").upper()
            for key in ("name", "official_name", "common_name"):
                name = row.get(key)
                if code and name:
                    translated = trans.gettext(name)
                    if translated and translated != name:
                        countries[translated.casefold()] = code

norm = re.sub(r"[._-]+", " ", q.casefold()).strip()
code = aliases.get(q.casefold()) or aliases.get(norm)
if not code:
    if len(q) == 2 and q.isascii() and q.isalpha():
        code = q.upper()
    else:
        code = countries.get(norm)
        if not code:
            partial = sorted({v for k,v in countries.items() if norm in k})
            if len(partial) == 1:
                code = partial[0]

zones = []
try:
    for line in open(zone_tab, encoding="utf-8"):
        if not line or line.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            codes, zone = parts[0].split(","), parts[2]
            if code and code in codes:
                zones.append(zone)
except OSError:
    pass

# ISO 3166 includes two uninhabited territories without their own zone.tab
# entries. Use the administrating/nearest matching IANA zones.
country_zone_defaults = {
    "BV": "Europe/Oslo",       # Bouvet Island (Norway)
    "HM": "Indian/Kerguelen",  # Heard/McDonald Islands, UTC+5 region
}
if not zones and code in country_zone_defaults:
    zones.append(country_zone_defaults[code])

if not zones and not code:
    # Match a city or any fragment in installed canonical timezones.
    needle = q.casefold().replace(" ", "_")
    try:
        candidates = subprocess_output = os.popen("timedatectl list-timezones 2>/dev/null").read().splitlines()
    except Exception:
        candidates = []
    zones = [z for z in candidates if needle in z.casefold()]

for zone in dict.fromkeys(zones):
    print(zone)
PY
}

CHOSEN_TIMEZONE=""

choose_timezone() {
    local query=${1:-} current count choice selected
    local -a zones=()
    current=$(get_configured_timezone)

    if [[ -z "$query" ]]; then
        echo
        printf '%b\n' "${C_CYAN}===== 选择时区 =====${C_RESET}"
        echo "支持输入：香港 / hk / 台湾 / tw / 日本 / jp / 美国 / us"
        echo "也支持：France / GB / London / America/New_York 等任何国家、城市或标准时区"
        echo "当前时区：$current"
        read -r -p "请输入地区（直接回车保留当前时区）：" query </dev/tty
        [[ -n "$query" ]] || query="$current"
    fi

    mapfile -t zones < <(resolve_timezones "$query" | sed '/^$/d')
    count=${#zones[@]}

    if (( count == 0 )); then
        err "无法识别地区：$query"
        warn "可输入标准时区，例如 Asia/Hong_Kong；查看全部：timedatectl list-timezones"
        return 1
    elif (( count == 1 )); then
        selected=${zones[0]}
    else
        echo
        info "该地区有多个时区，请选择："
        local i
        for i in "${!zones[@]}"; do
            printf '%2d. %s\n' "$((i + 1))" "${zones[$i]}"
        done

        if [[ ! -t 0 || ! -r /dev/tty ]]; then
            err "地区 $query 包含多个时区，非交互模式下请直接指定标准时区，例如 America/New_York"
            return 1
        fi

        while true; do
            read -r -p "请输入编号 [1-$count]：" choice </dev/tty
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
                selected=${zones[$((choice - 1))]}
                break
            fi
            warn "编号无效，请重新输入"
        done
    fi

    [[ -e "/usr/share/zoneinfo/$selected" ]] || { err "系统中不存在时区：$selected"; return 1; }
    CHOSEN_TIMEZONE="$selected"
    ok "已识别时区：$selected"
}

http_date_offset() {
    local url=$1 header server_epoch start_ms end_ms midpoint_ms
    start_ms=$(date +%s%3N)
    header=$(curl -fsSI --max-time 12 \
        -H 'Cache-Control: no-cache' \
        -H 'User-Agent: time-sync-manager/1.2' \
        "${url}?_ts=$(date +%s%N)" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Dd]ate:[[:space:]]*//p' | head -n1 || true)
    end_ms=$(date +%s%3N)
    [[ -n "$header" ]] || return 1
    server_epoch=$(date -u -d "$header" +%s 2>/dev/null) || return 1
    midpoint_ms=$(((start_ms + end_ms) / 2))
    # HTTP Date has one-second precision. Compare it with the local midpoint
    # of the request to compensate roughly half of the network round trip.
    printf '%s\n' "$((server_epoch - midpoint_ms / 1000))"
}

manual_coarse_time() {
    local answer input parsed timezone

    if [[ ! -t 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
        err "当前为后台/非交互运行，无法询问时间"
        err "请在终端执行：sudo time-sync-manager --sync，然后按提示输入手机上的当前时间"
        return 1
    fi

    timezone=$(get_configured_timezone)
    echo
    warn "系统日期可能偏差过大，导致 HTTPS 证书无法验证"
    read -r -p "是否根据手机时间手动粗调？[y/N]：" answer </dev/tty
    case "$answer" in
        y|Y|yes|YES|是) ;;
        *) warn "已取消手动粗调"; return 1 ;;
    esac

    while true; do
        echo "当前时区：$timezone"
        read -r -p "请输入当前时间（格式：YYYY-MM-DD HH:MM:SS）：" input </dev/tty

        if [[ ! "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            warn "格式错误，例如：2026-08-16 14:30:00"
            continue
        fi

        parsed=$(date -d "$input" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
        if [[ "$parsed" != "$input" ]]; then
            warn "日期或时间无效，请重新输入"
            continue
        fi

        local year=${input:0:4}
        if (( 10#$year < 2020 || 10#$year > 2100 )); then
            warn "年份应在 2020 至 2100 之间，请检查输入"
            continue
        fi
        break
    done

    timedatectl set-ntp false
    if ! date -s "$input" >/dev/null; then
        err "手动粗调失败，正在恢复 NTP"
        timedatectl set-ntp true || true
        systemctl restart systemd-timesyncd || true
        return 1
    fi
    timedatectl set-ntp true || true
    systemctl restart systemd-timesyncd || true
    ok "已按 $timezone 粗调系统时间，正在重新尝试 HTTPS 精确校时"
    logger -t "$LOG_TAG" "Manual coarse time applied: timezone=$timezone input=$input"
}

https_sync() {
    local allow_prompt=${1:-true}
    local -a urls=(
        "https://www.cloudflare.com/"
        "https://www.google.com/generate_204"
        "https://www.microsoft.com/"
    )
    local -a offsets=()
    local url source_offset target before after offset min_offset max_offset spread

    info "NTP 未同步，尝试 HTTPS（TCP 443）备用校时……"
    for url in "${urls[@]}"; do
        if source_offset=$(http_date_offset "$url"); then
            offsets+=("$source_offset")
            info "已取得时间源：$url（偏差 ${source_offset} 秒）"
        else
            warn "时间源不可用：$url"
        fi
    done

    if (( ${#offsets[@]} < 2 )); then
        err "HTTPS 校时失败：可用时间源少于 2 个"
        err "可能是系统日期偏差过大，导致 TLS 证书验证失败；本脚本不会使用不安全的 curl -k"
        logger -t "$LOG_TAG" "HTTPS sync failed: fewer than 2 sources"

        if [[ "$allow_prompt" == true ]] && manual_coarse_time; then
            https_sync false
            return
        fi
        return 1
    fi

    mapfile -t offsets < <(printf '%s\n' "${offsets[@]}" | sort -n)
    min_offset=${offsets[0]}
    max_offset=${offsets[$(( ${#offsets[@]} - 1 ))]}
    spread=$((max_offset - min_offset))
    if (( spread > MAX_HTTPS_SOURCE_SPREAD )); then
        err "HTTPS 时间源计算出的偏差相差 ${spread} 秒，超过安全阈值 ${MAX_HTTPS_SOURCE_SPREAD} 秒，拒绝校时"
        logger -t "$LOG_TAG" "HTTPS sync rejected: offset spread=${spread}s"
        return 1
    fi

    offset=${offsets[$(( ${#offsets[@]} / 2 ))]}
    before=$(date +%s)
    target=$((before + offset))

    if (( offset >= -1 && offset <= 1 )); then
        ok "HTTPS 时间与本机偏差仅 ${offset} 秒，无需调整系统时钟"
        logger -t "$LOG_TAG" "HTTPS check healthy: sources=${#offsets[@]} offset=${offset}s"
        return 0
    fi

    if ! timedatectl set-ntp false; then
        err "无法暂时关闭 NTP，HTTPS 校时已取消"
        return 1
    fi

    local sync_rc=0
    if ! date -u -s "@$target" >/dev/null; then
        err "设置系统时间失败"
        sync_rc=1
    fi

    # 无论设置时间是否成功，都必须尽力恢复 NTP 服务。
    if ! timedatectl set-ntp true; then
        err "重新启用 NTP 失败，请检查 systemd-timesyncd"
        sync_rc=1
    fi
    if ! systemctl restart systemd-timesyncd; then
        err "系统时间已通过 HTTPS 调整，但重启 systemd-timesyncd 失败"
        logger -t "$LOG_TAG" "HTTPS clock adjusted but timesyncd restart failed: offset=${offset}s"
        sync_rc=1
    fi
    (( sync_rc == 0 )) || return 1

    after=$(date +%s)
    ok "HTTPS 校时成功，修正偏差：${offset} 秒"
    logger -t "$LOG_TAG" "HTTPS sync successful: sources=${#offsets[@]} offset=${offset}s now=${after}"
}

sync_now() {
    require_root
    check_supported_system
    local timezone
    exec 9>/run/time-sync-manager.lock
    if ! flock -n 9; then
        warn "已有另一个时间同步任务正在运行，本次退出"
        return 0
    fi
    timezone=$(get_configured_timezone)

    info "当前配置时区：$timezone"
    timedatectl set-timezone "$timezone"
    local ntp_service_ready=true
    if ! systemctl enable --now systemd-timesyncd >/dev/null; then
        warn "systemd-timesyncd 无法启用，将直接尝试 HTTPS 备用校时"
        ntp_service_ready=false
    fi

    if [[ "$ntp_service_ready" != true ]]; then
        https_sync
        timedatectl
        return
    fi

    # 主动探测当前 NTP UDP 123 是否可用；只有探测可达时才信任
    # timesyncd 的同步状态，避免“历史 yes”掩盖后续网络故障。
    if ! ntp_udp_reachable; then
        warn "检测到 NTP UDP 123 无响应，直接启用 HTTPS 备用校时"
        https_sync
        timedatectl
        return
    fi

    if ntp_synced; then
        ok "NTP UDP 123 可达且当前已同步，无需备用校时"
        logger -t "$LOG_TAG" "NTP reachable and synchronized"
        timedatectl
        return 0
    fi

    systemctl restart systemd-timesyncd
    info "NTP UDP 123 可达，等待 systemd-timesyncd 同步，最多 ${NTP_WAIT_SECONDS} 秒……"
    local waited=0
    while (( waited < NTP_WAIT_SECONDS )); do
        if ntp_synced; then
            ok "NTP（UDP 123）同步成功"
            logger -t "$LOG_TAG" "NTP sync successful after ${waited}s"
            timedatectl
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    https_sync
    timedatectl
}

write_units() {
    cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Time synchronization with NTP and HTTPS fallback
Wants=network-online.target
After=network-online.target systemd-timesyncd.service

[Service]
Type=oneshot
TimeoutStartSec=3min
ExecStart=${SELF_PATH} --sync
EOF_SERVICE

    cat >"$TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Run time synchronization every 4 hours

[Timer]
OnBootSec=2min
OnUnitActiveSec=4h
RandomizedDelaySec=2min
AccuracySec=1min
Unit=time-sync-manager.service

[Install]
WantedBy=timers.target
EOF_TIMER
}

install_manager() {
    require_root
    check_supported_system

    local timezone source_path query=${1:-}
    # Before apt/timezone/systemd mutations, resolve a durable source copy.
    source_path=$(source_script_path) || return 1
    check_time_daemon_conflicts
    install_dependencies

    if [[ -n "$query" ]]; then
        choose_timezone "$query" || return 1
    else
        while ! choose_timezone; do :; done
    fi
    timezone="$CHOSEN_TIMEZONE"

    save_timezone "$timezone"
    timedatectl set-timezone "$timezone"

    info "安装管理脚本和 systemd 定时任务……"
    if [[ "$source_path" != "$SELF_PATH" ]]; then
        install -m 0755 "$source_path" "$SELF_PATH"
    else
        chmod 0755 "$SELF_PATH"
    fi
    if [[ "$source_path" == /tmp/time-sync-manager.download.* && "$source_path" != "${BASH_SOURCE[0]}" ]]; then
        rm -f "$source_path"
    fi
    write_units
    systemctl daemon-reload
    systemctl enable --now time-sync-manager.timer
    systemctl enable --now systemd-timesyncd

    ok "安装完成：时区 $timezone；开机同步；此后每 4 小时同步一次"
    systemctl list-timers time-sync-manager.timer --all --no-pager || true
    info "立即执行第一次同步……"
    systemctl start time-sync-manager.service
    show_status
}

change_timezone() {
    require_root
    check_supported_system
    if ! timezone_tools_ready; then
        err "时区识别组件尚未安装，请先选择菜单 1 完成安装"
        return 1
    fi
    local timezone query=${1:-}
    if [[ -n "$query" ]]; then
        choose_timezone "$query" || return 1
    else
        while ! choose_timezone; do :; done
    fi
    timezone="$CHOSEN_TIMEZONE"
    save_timezone "$timezone"
    timedatectl set-timezone "$timezone"
    ok "时区已改为：$timezone"
    timedatectl
}

show_status() {
    printf '\n%b\n' "${C_CYAN}===== 时间与同步状态 =====${C_RESET}"
    printf '脚本配置时区：%s\n' "$(get_configured_timezone)"
    timedatectl 2>/dev/null || true

    printf '\n%b\n' "${C_CYAN}===== 服务状态 =====${C_RESET}"
    printf 'systemd-timesyncd：%s / %s\n' \
        "$(systemctl is-active systemd-timesyncd 2>/dev/null || true)" \
        "$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)"
    printf '4小时定时器：%s / %s\n' \
        "$(systemctl is-active time-sync-manager.timer 2>/dev/null || true)" \
        "$(systemctl is-enabled time-sync-manager.timer 2>/dev/null || true)"

    printf '\n%b\n' "${C_CYAN}===== 下次同步时间 =====${C_RESET}"
    if systemctl is-enabled time-sync-manager.timer >/dev/null 2>&1; then
        systemctl list-timers time-sync-manager.timer --all --no-pager 2>/dev/null || true
    else
        warn "定时任务尚未安装"
    fi
}

show_logs() {
    printf '%b\n' "${C_CYAN}===== 最近同步日志 =====${C_RESET}"
    journalctl -u time-sync-manager.service -n 100 --no-pager 2>/dev/null || true
    printf '\n%b\n' "${C_CYAN}===== timesyncd 最近日志 =====${C_RESET}"
    journalctl -u systemd-timesyncd -n 50 --no-pager 2>/dev/null || true
}

uninstall_manager() {
    require_root
    local answer
    read -r -p "确认卸载本脚本及其定时任务？输入 YES 继续：" answer </dev/tty
    if [[ "$answer" != "YES" ]]; then
        warn "已取消卸载"
        return 0
    fi
    systemctl disable --now time-sync-manager.timer 2>/dev/null || true
    systemctl stop time-sync-manager.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SELF_PATH" "$CONFIG_FILE"
    systemctl daemon-reload
    systemctl reset-failed time-sync-manager.service 2>/dev/null || true
    ok "已卸载 HTTPS 备用校时和 4 小时定时器"
    warn "systemd-timesyncd 保留运行，未被卸载"
}

print_help() {
    cat <<EOF_HELP
Time Sync Manager v${VERSION}（Ubuntu / Debian）

用法：
  bash time-sync-manager.sh                  打开交互菜单
  bash time-sync-manager.sh --install [地区] 安装，可传 香港/hk/JP/France/Asia/Taipei
  ${SELF_PATH} --sync                        立即同步
  ${SELF_PATH} --timezone [地区]              修改时区
  ${SELF_PATH} --status                      查看状态
  ${SELF_PATH} --logs                        查看日志
  ${SELF_PATH} --uninstall                   卸载定时任务
EOF_HELP
}

menu() {
    if [[ ! -t 0 || ! -t 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
        err "交互菜单需要终端。请先下载脚本后在 SSH/终端中运行，或使用 --install/--status 等参数"
        return 1
    fi
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${C_CYAN}========================================${C_RESET}"
        printf '%b\n' "${C_CYAN} 时间同步管理器 v${VERSION}（Ubuntu/Debian）${C_RESET}"
        printf '%b\n' "${C_CYAN} NTP优先 / HTTPS备用 / 每4小时${C_RESET}"
        printf '%b\n' "${C_CYAN}========================================${C_RESET}"
        echo "1. 安装或更新时间同步"
        echo "2. 立即同步一次"
        echo "3. 查看同步状态"
        echo "4. 查看同步日志"
        echo "5. 修改地区/时区"
        echo "6. 卸载本定时同步功能"
        echo "0. 退出"
        echo

        local choice
        read -r -p "请选择 [0-6]：" choice </dev/tty
        case "$choice" in
            1) install_manager || warn "安装/更新失败，请查看上方错误" ;;
            2) sync_now || warn "同步失败，请查看同步日志" ;;
            3) show_status || true ;;
            4) show_logs || true ;;
            5) change_timezone || warn "修改时区失败" ;;
            6) uninstall_manager || warn "卸载未完成" ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo
        read -r -p "按回车键返回菜单……" _ </dev/tty
    done
}

if [[ "${TIME_SYNC_MANAGER_LIB:-0}" != "1" ]]; then
case "${1:-}" in
    --install)
        (( $# <= 2 )) || { err "--install 最多接受一个地区参数"; exit 2; }
        install_manager "${2:-}"
        ;;
    --sync)
        (( $# == 1 )) || { err "--sync 不接受额外参数"; exit 2; }
        sync_now
        ;;
    --timezone)
        (( $# <= 2 )) || { err "--timezone 最多接受一个地区参数"; exit 2; }
        change_timezone "${2:-}"
        ;;
    --status)
        (( $# == 1 )) || { err "--status 不接受额外参数"; exit 2; }
        show_status
        ;;
    --logs)
        (( $# == 1 )) || { err "--logs 不接受额外参数"; exit 2; }
        show_logs
        ;;
    --uninstall)
        (( $# == 1 )) || { err "--uninstall 不接受额外参数"; exit 2; }
        uninstall_manager
        ;;
    --resolve)
        (( $# == 2 )) || { err "--resolve 需要且只接受一个地区参数"; exit 2; }
        resolve_timezones "$2"
        ;;
    -h|--help)
        (( $# == 1 )) || { err "--help 不接受额外参数"; exit 2; }
        print_help
        ;;
    "") menu ;;
    *) err "未知参数：$1"; print_help; exit 2 ;;
esac
fi
