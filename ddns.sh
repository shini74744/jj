#!/bin/sh
# Cloudflare 多域名 DDNS 管理器 2.0.2
# 用法：支持本地文件或 bash <(curl -fsSL GitHub原始链接)；安装后执行 cloudflare-ddns。
# 保留 IPv4/A 记录模式；所有启用的域名同步为本机同一个直连出口 IPv4。
# 支持 systemd / OpenRC；不修改系统 DNS、路由、时区及宿主机设置。
# 配置包含 API Token，请勿公开 /etc/cloudflare-ddns/config.json 及其备份。
# API 依据：https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/

set -u
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL

VERSION='2.0.2'
# GitHub 进程替换/管道入口需要重新下载为普通文件；迁移仓库时修改此地址。
# 仅启动安装/菜单入口时使用；安装后的定时同步不会从 GitHub 下载或自动升级。
SCRIPT_URL='https://raw.githubusercontent.com/shini74744/jj/refs/heads/main/ddns.sh'
INSTALL_SOURCE=''
SOURCE_KIND='file'
BOOT_DIR=''
BOOT_CHILD=''
CONFIG_DIR='/etc/cloudflare-ddns'
CONFIG_FILE="$CONFIG_DIR/config.json"
LEGACY_CONFIG='/etc/cloudflare-ddns.env'
MANAGER='/usr/local/sbin/cloudflare-ddns'
RUNTIME='/usr/local/sbin/cloudflare-ddns-update'
COMPAT='/root/cf_ddns.sh'
LOOP='/usr/local/sbin/cloudflare-ddns-loop'
STATE_DIR='/var/lib/cloudflare-ddns'
WORK_ROOT='/run/cloudflare-ddns'
RUN_LOCK='/run/lock/cloudflare-ddns.lock'
MANAGE_LOCK='/run/lock/cloudflare-ddns-manage.lock'
LOOP_LOCK='/run/lock/cloudflare-ddns-loop.lock'
LOG_FILE='/var/log/cf_ddns.log'
SERVICE='/etc/systemd/system/cf-ddns.service'
TIMER='/etc/systemd/system/cf-ddns.timer'
OPENRC_SERVICE='/etc/init.d/cf-ddns'
OLD_LOGROTATE='/etc/logrotate.d/cf-ddns'
API_BASE='https://api.cloudflare.com/client/v4'
WORK=''
CHILD=''
TTY_STATE=''
SELF=''
INIT=''
API_ERROR=''
API_HTTP=''
API_COOLDOWN_FILE="$STATE_DIR/api-not-before"
API_COOLDOWN_LOCK='/run/lock/cloudflare-ddns-api.lock'

say() { printf '%s\n' "$*"; }
err() { printf '错误：%s\n' "$*" >&2; }
pause() { printf '按回车返回菜单...'; IFS= read -r _pause || :; }
ask() { printf '%s' "$1"; IFS= read -r REPLY; }

# ---------- GitHub 一键入口：先落盘、校验，再运行；绝不从已读过的管道复制自身 ----------
valid_script_source() {
    [ -f "$1" ] && [ -s "$1" ] && [ -r "$1" ] || return 1
    [ "$(head -n 1 "$1")" = '#!/bin/sh' ] || return 1
    grep -Fqx "VERSION='$VERSION'" "$1" || return 1
    [ "$(tail -n 1 "$1")" = "# CF_DDNS_SOURCE_END $VERSION" ] || return 1
    /bin/sh -n "$1" || return 1
}
bootstrap_cleanup() {
    if [ -n "$BOOT_CHILD" ]; then
        kill -TERM "$BOOT_CHILD" 2>/dev/null || :
        wait "$BOOT_CHILD" 2>/dev/null || :
        BOOT_CHILD=''
    fi
    case "$BOOT_DIR" in /tmp/cloudflare-ddns-bootstrap.*) rm -rf -- "$BOOT_DIR" ;; esac
}
bootstrap_stream() {
    # curl | sh 的标准输入是脚本正文，不能继续用来读菜单；交互菜单改读终端。
    BOOT_USE_TTY=false
    if [ "$SOURCE_KIND" = stdin ]; then
        case "${1:---menu}" in
            --menu)
                if ! ( : < /dev/tty ) 2>/dev/null; then
                    err '管道入口没有可用终端；请下载成文件后运行，或使用 bash <(curl -fsSL URL)。'
                    return 1
                fi
                BOOT_USE_TTY=true
                ;;
        esac
    fi
    command -v curl >/dev/null 2>&1 || { err '一键入口需要 curl；请先安装 curl，或下载脚本后执行。'; return 1; }
    BOOT_DIR=$(mktemp -d /tmp/cloudflare-ddns-bootstrap.XXXXXXXX) || return 1
    trap bootstrap_cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    chmod 700 "$BOOT_DIR" || return 1
    BOOT_FILE="$BOOT_DIR/ddns.sh"
    say '检测到流式执行入口：先从 GitHub 下载完整脚本并校验，再进入菜单。'
    # 进程替换中的 $0 通常是 /dev/fd/63；原流已被 shell 读取，不能 cat "$0" 拼出完整文件。
    # HTTPS 校验保持开启；-q 忽略默认 curl 配置，-f 拒绝 HTTP 错误页，下载失败不继续。
    if ! curl -q -fLsS --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 1 \
        --retry-max-time 150 --proto '=https' --proto-redir '=https' \
        -o "$BOOT_FILE" "$SCRIPT_URL"; then
        err '下载失败；未停止 DDNS 调度，也未迁移或覆盖配置。'
        return 1
    fi
    if ! valid_script_source "$BOOT_FILE"; then
        err "下载内容不完整、语法错误或版本不一致；请确认 GitHub 已上传完整 v$VERSION 文件。"
        err '本次未停止 DDNS 调度，也未迁移或覆盖配置。'
        return 1
    fi
    chmod 600 "$BOOT_FILE" || return 1
    if [ "$BOOT_USE_TTY" = true ]; then
        /bin/sh "$BOOT_FILE" "$@" < /dev/tty &
    elif [ "$SOURCE_KIND" = stdin ]; then
        /bin/sh "$BOOT_FILE" "$@" < /dev/null &
    else
        # 显式保留标准输入，避免后台子进程的菜单被重定向到 /dev/null。
        /bin/sh "$BOOT_FILE" "$@" <&0 &
    fi
    BOOT_CHILD=$!
    wait "$BOOT_CHILD"; BOOT_RC=$?
    BOOT_CHILD=''
    return "$BOOT_RC"
}
stage_install_source() {
    # 必须在停止旧服务、迁移配置之前执行；暂存副本避免安装时再次读取易变源文件。
    valid_script_source "$SELF" || {
        err '安装源不是完整、可读的普通脚本文件；原调度和配置未改动。'; return 1;
    }
    INSTALL_SOURCE="$WORK/install-source.sh"
    atomic_file "$INSTALL_SOURCE" 600 sh < "$SELF" && valid_script_source "$INSTALL_SOURCE" || {
        err '暂存或校验安装源失败；原调度和配置未改动。'; return 1;
    }
}

# ---------- 公共清理：恢复终端回显、结束子任务、清理含 Token 的临时文件 ----------
cleanup() {
    if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" 2>/dev/null || :; fi
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || :
        wait "$CHILD" 2>/dev/null || :
    fi
    case "$WORK" in "$WORK_ROOT"/work.*) rm -rf -- "$WORK" ;; esac
}
set_cleanup() {
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}
new_work() {
    WORK=$(mktemp -d "$WORK_ROOT/work.XXXXXXXX") || return 1
    chmod 700 "$WORK" || return 1
    set_cleanup
}

prepare_dirs() {
    mkdir -p "$CONFIG_DIR" "$STATE_DIR/records" "$WORK_ROOT" /run/lock "$(dirname "$LOG_FILE")" || return 1
    chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$STATE_DIR/records" "$WORK_ROOT" || return 1
    if [ -L "$LOG_FILE" ]; then err "日志文件不允许是符号链接：$LOG_FILE"; return 1; fi
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
}

check_deps() {
    for dep in curl jq flock timeout awk sed mktemp sha256sum; do
        command -v "$dep" >/dev/null 2>&1 || { err "缺少依赖 $dep，请先选择安装/更新。"; return 1; }
    done
}
install_deps() {
    say '检查并安装 curl、jq、flock、timeout 和 CA 证书...'
    if check_deps >/dev/null 2>&1 &&
       timeout --version 2>/dev/null | grep -q 'GNU coreutils' &&
       { [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/pki/tls/certs/ca-bundle.crt ]; }; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq util-linux coreutils ca-certificates || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq util-linux coreutils ca-certificates || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq util-linux coreutils ca-certificates || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl jq util-linux coreutils ca-certificates || return 1
    else
        err '未识别包管理器，请手工安装上述依赖后重试。'; return 1
    fi
    check_deps
}

# 不仅检查 systemctl 是否存在，还确认 systemd 可实际通信。
detect_init() {
    INIT=''
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 &&
       systemctl show --property=Version >/dev/null 2>&1; then
        INIT=systemd
    elif [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1 &&
         command -v rc-update >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
        INIT=openrc
    else
        err '未检测到可运行的 systemd/OpenRC；普通容器中不能仅凭存在 systemctl 就安装服务。'
        return 1
    fi
}

# ---------- 格式校验：不执行配置内容，不允许 shell 代码混入配置 ----------
normalize_domain() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\.$//'; }
valid_domain() {
    printf '%s\n' "$1" | awk -F. '
        NR!=1 || length($0)>253 || NF<2 {exit 1}
        {for(i=1;i<=NF;i++) if(length($i)<1 || length($i)>63 ||
          $i !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) exit 1
         if($NF !~ /[a-z]/) exit 1}
    '
}
valid_token() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac; }
valid_id() { [ "${#1}" -eq 32 ] && case "$1" in *[!a-f0-9]*) return 1 ;; *) return 0 ;; esac; }
belongs_to_zone() { case "$1" in "$2"|*."$2") return 0 ;; *) return 1 ;; esac; }
valid_interval() {
    case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 30 ] && [ "$1" -le 86400 ]
}
valid_config() {
    # -s 先收集整个输入；必须恰好一个顶层 JSON 对象，拒绝拼接的多份配置。
    jq -es '
      def host: type=="string" and length<=253 and
        test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$") and
        (split(".")|all(.[]; length<=63)) and (split(".")[-1]|test("[a-z]"));
      length==1 and (.[0] | type=="object" and
      .version==2 and (.interval|type=="number") and
      (.interval>=30 and .interval<=86400 and .interval==(.interval|floor)) and
      (.records|type=="array") and
      (.records|all(.[];
        (.name|host) and (.zone|host) and (.enabled|type=="boolean") and
        (.token|type=="string" and test("^[A-Za-z0-9_-]+$")) and
        (.zone_id|type=="string" and (length==0 or test("^[a-f0-9]{32}$"))) and
        (. as $r|$r.name==$r.zone or ($r.name|endswith("."+$r.zone))))) and
      ((.records|map(.name)|unique|length)==(.records|length)))
    ' "$1" >/dev/null 2>&1
}
need_config() {
    check_deps || return 1
    [ -f "$CONFIG_FILE" ] || { err '尚无配置，请先选择 1 安装/更新。'; return 1; }
    valid_config "$CONFIG_FILE" || { err '配置格式不正确；为防止误更新，已停止操作。'; return 1; }
}

# 参数只包含域名等非机密数据；Token 通过私有临时文件传给 jq/curl，不进入命令行参数。
read_token() {
    printf 'Cloudflare API Token（不回显；直接回车取消）：'
    TTY_STATE=''
    if [ -t 0 ]; then
        TTY_STATE=$(stty -g) || return 1
        stty -echo || return 1
    fi
    IFS= read -r TOKEN || TOKEN=''
    if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" || return 1; TTY_STATE=''; fi
    printf '\n'
    valid_token "$TOKEN" || { err 'Token 为空或含非法字符。'; return 1; }
    printf '%s' "$TOKEN" > "$WORK/token" || return 1
    unset TOKEN
}
make_auth() {
    IFS= read -r AUTH_TOKEN < "$WORK/token" || :
    valid_token "${AUTH_TOKEN:-}" || { API_ERROR='Token 格式不正确'; return 1; }
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
        "$AUTH_TOKEN" > "$WORK/auth" || return 1
    unset AUTH_TOKEN
}
mask_message() {
    jq -Rrs --rawfile token "$WORK/token" '
      (if ($token|length)>0 then split($token)|join("[REDACTED]") else . end)
      |gsub("[\\x00-\\x1f\\x7f]";" ")|sub("^ +";"")|sub(" +$";"")|.[0:500]' 2>/dev/null
}

# ---------- API 限流冷却：429 后暂停本机所有账户的 API 请求 ----------
# Cloudflare 可能按用户/账户或出口 IP 限流。保守地共享冷却状态；不记录 Token。
# 菜单与定时轮次都检查，不能通过“立即同步”绕过 Retry-After。
check_api_cooldown() {
    if [ -n "${API_BLOCKED_ERROR:-}" ]; then API_ERROR=$API_BLOCKED_ERROR; return 1; fi
    [ -e "$API_COOLDOWN_FILE" ] || return 0
    [ -f "$API_COOLDOWN_FILE" ] || { API_ERROR='API 限流状态路径不是普通文件'; return 1; }
    CD_UNTIL=$(cat "$API_COOLDOWN_FILE") || { API_ERROR='读取 API 限流状态失败'; return 1; }
    case "$CD_UNTIL" in ''|*[!0-9]*|0*) API_ERROR='API 限流状态损坏，请检查 api-not-before 文件'; return 1 ;; esac
    [ "${#CD_UNTIL}" -le 10 ] || { API_ERROR='API 限流时间异常'; return 1; }
    CD_NOW=$(date +%s) || { API_ERROR='无法读取系统时间'; return 1; }
    if [ "$CD_UNTIL" -gt "$CD_NOW" ]; then
        API_HTTP=429
        API_ERROR="HTTP=429 限流冷却中，约 $((CD_UNTIL - CD_NOW)) 秒后恢复；本次不请求 Cloudflare。"
        return 1
    fi
    return 0
}
set_api_cooldown() (
    # 独立锁避免菜单与定时器同时遇到 429 时，较短的冷却覆盖较长的冷却。
    exec 6>"$API_COOLDOWN_LOCK" || exit 1
    flock -w 5 6 || exit 1
    CD_NOW=$(date +%s) || exit 1
    CD_DELAY=300
    CD_HEADER=$(awk 'tolower($0) ~ /^retry-after[[:space:]]*:/ {
        sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); value=$0
      } END {print value}' "$WORK/headers") || exit 1
    case "$CD_HEADER" in
        ''|*[!0-9]*)
            if [ -n "$CD_HEADER" ]; then
                CD_DATE=$(date -u -d "$CD_HEADER" +%s 2>/dev/null) || CD_DATE=0
                if [ "$CD_DATE" -gt "$CD_NOW" ]; then CD_DELAY=$((CD_DATE - CD_NOW)); fi
            fi
            ;;
        *)
            CD_NUMBER=$(printf '%s' "$CD_HEADER" | sed 's/^0*//')
            CD_NUMBER=${CD_NUMBER:-0}
            if [ "${#CD_NUMBER}" -le 8 ]; then CD_DELAY=$CD_NUMBER; fi
            ;;
    esac
    # 无有效头时用 300 秒；即使服务器给出 0，也至少间隔 1 秒，防止紧密循环。
    [ "$CD_DELAY" -ge 1 ] || CD_DELAY=1
    CD_UNTIL=$((CD_NOW + CD_DELAY))
    if [ -f "$API_COOLDOWN_FILE" ]; then
        CD_OLD=$(cat "$API_COOLDOWN_FILE") || exit 1
        case "$CD_OLD" in ''|*[!0-9]*|0*) CD_OLD=0 ;; esac
        if [ "${#CD_OLD}" -le 10 ] && [ "$CD_OLD" -gt "$CD_UNTIL" ]; then CD_UNTIL=$CD_OLD; fi
    fi
    printf '%s\n' "$CD_UNTIL" | atomic_file "$API_COOLDOWN_FILE" 600
)

# ---------- HTTP/API：单次 12 秒，GET/PATCH 遇临时故障最多重试一次 ----------
# 不使用 -f 吞响应正文；429 写入持久冷却状态，后续域名和下一轮均遵守。
cf_call() {
    CF_METHOD=$1; CF_PATH=$2; CF_DATA=${3:-}
    API_ERROR=''; API_HTTP=''; CF_ATTEMPT=1
    check_api_cooldown || return 1
    while [ "$CF_ATTEMPT" -le 2 ]; do
        check_api_cooldown || return 1
        : > "$WORK/body" && : > "$WORK/curl.err" && : > "$WORK/headers" || {
            API_ERROR='创建 HTTP 临时文件失败'; return 1;
        }
        if [ -n "$CF_DATA" ]; then
            API_HTTP=$(curl -q -4 --noproxy '*' -sS --connect-timeout 4 --max-time 12 \
                --proto '=https' --config "$WORK/auth" -X "$CF_METHOD" \
                --data-binary "@$CF_DATA" -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' \
                "$API_BASE$CF_PATH" 2>"$WORK/curl.err")
            CF_RC=$?
        else
            API_HTTP=$(curl -q -4 --noproxy '*' -sS --connect-timeout 4 --max-time 12 \
                --proto '=https' --config "$WORK/auth" -X "$CF_METHOD" \
                -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' "$API_BASE$CF_PATH" 2>"$WORK/curl.err")
            CF_RC=$?
        fi
        if [ "$CF_RC" -eq 0 ] && case "$API_HTTP" in 2??) true ;; *) false ;; esac; then
            if jq -es 'length==1 and (.[0]|type=="object" and .success==true)' "$WORK/body" >/dev/null 2>&1; then return 0; fi
        fi
        if [ "$CF_RC" -ne 0 ]; then
            CF_DETAIL=$(mask_message < "$WORK/curl.err")
            API_ERROR="curl=$CF_RC HTTP=${API_HTTP:-000} ${CF_DETAIL:-网络/TLS/解析错误}"
        else
            CF_DETAIL=$(jq -r 'if type=="object" then
              [.errors[]? | "\(.code // "?"): \(.message // "未知 API 错误")"]|join("; ")
              else empty end' "$WORK/body" 2>/dev/null | mask_message)
            API_ERROR="HTTP=${API_HTTP:-000} ${CF_DETAIL:-空响应、非 JSON 响应或 success 不为 true}"
        fi
        if [ "$API_HTTP" = 429 ]; then
            if ! set_api_cooldown; then
                API_ERROR="$API_ERROR；保存限流冷却失败，请检查本地存储。"
                API_BLOCKED_ERROR=$API_ERROR
            else
                API_ERROR="$API_ERROR；已设置本机 API 冷却。"
            fi
            return 1
        fi
        CF_RETRY=false
        case "$CF_METHOD" in GET|PATCH)
            case "$CF_RC:$API_HTTP" in 5:*|6:*|7:*|18:*|28:*|35:*|52:*|55:*|56:*|0:500|0:502|0:503|0:504) CF_RETRY=true ;; esac
        ;; esac
        if [ "$CF_RETRY" != true ] || [ "$CF_ATTEMPT" -eq 2 ]; then return 1; fi
        CF_ATTEMPT=$((CF_ATTEMPT + 1)); sleep 1
    done
    return 1
}
lookup_zone() {
    cf_call GET "/zones?name=$ZONE&per_page=50" || return 1
    ZONE_COUNT=$(jq --arg z "$ZONE" '[.result[]? | select(.name==$z)]|length' "$WORK/body") || return 1
    [ "$ZONE_COUNT" -eq 1 ] || { API_ERROR="Zone $ZONE 未唯一匹配；检查名称、Token 的 Zone:Read 权限及资源范围。"; return 1; }
    ZONE_ID=$(jq -r --arg z "$ZONE" '.result[]|select(.name==$z)|.id' "$WORK/body") || return 1
    valid_id "$ZONE_ID" || { API_ERROR='Zone ID 格式异常'; return 1; }
}
lookup_record() {
    cf_call GET "/zones/$ZONE_ID/dns_records?type=A&name.exact=$NAME&per_page=100" || return 1
    jq -e '.result|type=="array"' "$WORK/body" >/dev/null 2>&1 || { API_ERROR='记录列表格式异常'; return 1; }
    # 无论分页中多少条，只要超过一条就拒绝，不默默选 result[0]。
    RECORD_COUNT=$(jq --arg n "$NAME" '[.result[]|select(.type=="A" and .name==$n)]|length' "$WORK/body") || return 1
    TOTAL_COUNT=$(jq -e '.result_info.total_count // (.result|length) |
        select(type=="number" and .>=0 and .==floor)' "$WORK/body") || {
        API_ERROR='记录分页统计格式异常'; return 1;
    }
    if [ "$RECORD_COUNT" -gt 1 ] || [ "$TOTAL_COUNT" -gt 1 ]; then
        API_ERROR="$NAME 存在多条同名 A 记录；请先在 Cloudflare 整理为一条。"; return 1
    fi
    if [ "$RECORD_COUNT" -eq 0 ]; then API_ERROR="$NAME 没有 A 记录；请在菜单添加时创建，或先到 Cloudflare 创建。"; return 2; fi
    jq --arg n "$NAME" '.result[]|select(.type=="A" and .name==$n)' "$WORK/body" > "$WORK/record" || return 1
    RECORD_ID=$(jq -r '.id' "$WORK/record") || return 1
    valid_id "$RECORD_ID" || { API_ERROR='DNS 记录 ID 格式异常'; return 1; }
}

# ---------- IPv4：排除常见非公网地址；同一轮两次一致才允许同步 ----------
is_public_ipv4() {
    printf '%s\n' "$1" | awk -F. '
      NR!=1 || NF!=4 {exit 1}
      {for(i=1;i<=4;i++) if($i !~ /^(0|[1-9][0-9]*)$/ || length($i)>3 || $i>255) exit 1
       a=$1+0;b=$2+0;c=$3+0
       if(a==0||a==10||a==127||a>=224||(a==100&&b>=64&&b<=127)||
          (a==169&&b==254)||(a==172&&b>=16&&b<=31)||(a==192&&b==168)||
          (a==198&&(b==18||b==19))||(a==192&&b==0&&(c==0||c==2))||
          (a==198&&b==51&&c==100)||(a==203&&b==0&&c==113)) exit 1}
    '
}
fetch_public_ip() {
    for IP_URL in 'https://cloudflare.com/cdn-cgi/trace' 'https://api.ipify.org' 'https://ipv4.icanhazip.com'; do
        IP_VALUE=$(curl -q -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 5 \
            --proto '=https' "$IP_URL" 2>/dev/null) || continue
        case "$IP_URL" in
            *cdn-cgi/trace) IP_VALUE=$(printf '%s\n' "$IP_VALUE" | sed -n 's/^ip=//p' | head -n 1 | tr -d '\r') ;;
            *) IP_VALUE=$(printf '%s' "$IP_VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') ;;
        esac
        if is_public_ipv4 "$IP_VALUE"; then printf '%s\n' "$IP_VALUE"; return 0; fi
    done
    return 1
}
get_stable_ip() {
    IP_PREVIOUS=''; IP_ATTEMPT=0; STABLE_IP=''
    while [ "$IP_ATTEMPT" -lt 4 ]; do
        IP_ATTEMPT=$((IP_ATTEMPT + 1))
        IP_CURRENT=$(fetch_public_ip) || IP_CURRENT=''
        if [ -n "$IP_CURRENT" ] && [ "$IP_CURRENT" = "$IP_PREVIOUS" ]; then STABLE_IP=$IP_CURRENT; return 0; fi
        IP_PREVIOUS=$IP_CURRENT
        [ "$IP_ATTEMPT" -eq 4 ] || sleep 1
    done
    return 1
}

# ---------- 日志及逐域名状态；内置轮转，不依赖 logrotate/cron 是否安装 ----------
rotate_log() {
    LOG_BYTES=$(wc -c < "$LOG_FILE") || return 1
    [ "$LOG_BYTES" -ge 2097152 ] || return 0
    rm -f "$LOG_FILE.5" || return 1
    ROT_I=4
    while [ "$ROT_I" -ge 1 ]; do
        [ ! -f "$LOG_FILE.$ROT_I" ] || mv -f "$LOG_FILE.$ROT_I" "$LOG_FILE.$((ROT_I + 1))" || return 1
        ROT_I=$((ROT_I - 1))
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1" && : > "$LOG_FILE" && chmod 600 "$LOG_FILE"
}
log() {
    LOG_LEVEL=$1; shift
    LOG_LINE="$(date '+%Y-%m-%d %H:%M:%S%z') [$LOG_LEVEL] $*"
    printf '%s\n' "$LOG_LINE" >> "$LOG_FILE" || return 1
    printf '%s\n' "$LOG_LINE" >&2
}
# 单个文件名通常最多 255 字节；253 字符域名再加 .json 会超限。
# 短域名沿用旧路径，超长域名使用 SHA-256 文件名，JSON 内仍保留完整域名。
record_state_path() {
    if [ "${#1}" -le 250 ]; then
        printf '%s/records/%s.json\n' "$STATE_DIR" "$1"
    else
        RSP_HASH=$(printf '%s' "$1" | sha256sum | awk '{print $1}') || return 1
        [ "${#RSP_HASH}" -eq 64 ] || return 1
        printf '%s/records/sha256-%s.json\n' "$STATE_DIR" "$RSP_HASH"
    fi
}
write_state() {
    STATE_STATUS=$1; STATE_MESSAGE=$2; STATE_IP=${3:-}; STATE_PROXY=${4:-null}
    STATE_PATH=$(record_state_path "$NAME") || return 1
    STATE_UPDATED=''
    [ ! -r "$STATE_PATH" ] || STATE_UPDATED=$(jq -r '.updated_at // ""' "$STATE_PATH" 2>/dev/null)
    [ "$STATE_STATUS" != updated ] || STATE_UPDATED=$(date '+%Y-%m-%d %H:%M:%S%z')
    jq -n --arg n "$NAME" --arg s "$STATE_STATUS" --arg m "$STATE_MESSAGE" \
        --arg ip "$STATE_IP" --arg t "$(date '+%Y-%m-%d %H:%M:%S%z')" \
        --arg u "$STATE_UPDATED" --argjson p "$STATE_PROXY" \
        '{name:$n,status:$s,message:$m,cloudflare_ip:$ip,checked_at:$t,updated_at:$u,proxied:$p}' \
        > "$WORK/state.next" && atomic_file "$STATE_PATH" 600 < "$WORK/state.next"
}
write_summary() {
    jq -n --arg status "$1" --arg message "$2" --arg ip "${STABLE_IP:-}" \
        --arg time "$(date '+%Y-%m-%d %H:%M:%S%z')" \
        '{status:$status,message:$message,public_ipv4:$ip,checked_at:$time}' \
        > "$WORK/summary.next" && atomic_file "$STATE_DIR/last-run.json" 600 < "$WORK/summary.next"
}

# ---------- 同步核心：一次探测、依次处理各域名；单个失败不跳过其他域名 ----------
sync_one() {
    NAME=$(jq -r '.name' "$WORK/current") || return 1
    ZONE=$(jq -r '.zone' "$WORK/current") || return 1
    ZONE_ID=$(jq -r '.zone_id' "$WORK/current") || return 1
    jq -jr '.token' "$WORK/current" > "$WORK/token" || return 1
    make_auth || return 1
    if [ -z "$ZONE_ID" ]; then lookup_zone || return 1; fi
    lookup_record || return 1
    OLD_IP=$(jq -r '.content' "$WORK/record") || return 1
    PROXIED=$(jq -r '.proxied' "$WORK/record") || return 1
    case "$PROXIED" in true|false) ;; *) API_ERROR='记录 proxied 字段异常'; return 1 ;; esac
    if [ "$OLD_IP" = "$STABLE_IP" ]; then
        write_state unchanged 'IP 一致，无需修改；已核对 Cloudflare API。' "$OLD_IP" "$PROXIED" || { API_ERROR='状态文件写入失败'; return 1; }
        SYNC_KIND=unchanged
        return 0
    fi
    # PATCH 只提交 content；不覆盖 TTL、橙云、备注、标签等其他属性。
    jq -n --arg ip "$STABLE_IP" '{content:$ip}' > "$WORK/patch" || return 1
    cf_call PATCH "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$WORK/patch" || return 1
    jq -e --arg id "$RECORD_ID" --arg n "$NAME" --arg ip "$STABLE_IP" \
        '.result.id==$id and .result.name==$n and .result.type=="A" and .result.content==$ip' \
        "$WORK/body" >/dev/null 2>&1 || { API_ERROR='API 返回成功，但记录 ID/名称/类型/IP 核对不一致。'; return 1; }
    # 以 API 结果作为写入确认，不把递归 DNS 缓存或橙云代理 IP 当作更新失败。
    NEW_PROXY=$(jq -r '.result.proxied' "$WORK/body") || return 1
    case "$NEW_PROXY" in true|false) ;; *) NEW_PROXY=$PROXIED ;; esac
    write_state updated '已更新并核对 API 返回值；公共 DNS 缓存可能稍后生效。' "$STABLE_IP" "$NEW_PROXY" || { API_ERROR='API 已更新，但状态文件写入失败'; return 1; }
    log INFO "$NAME：$OLD_IP -> $STABLE_IP（proxied=$NEW_PROXY）" || return 1
    SYNC_KIND=updated
}
sync_worker() {
    # 内部子进程必须继承父进程持有的 fd 9，避免绕过单实例锁。
    flock -n 9 2>/dev/null || { err '内部同步入口只能由 --run 调用。'; return 1; }
    WORK=$1
    case "$WORK" in "$WORK_ROOT"/work.*) ;; *) return 1 ;; esac
    valid_config "$WORK/snapshot.json" || { err '配置快照损坏。'; return 1; }
    ACTIVE_COUNT=$(jq '[.records[]|select(.enabled)]|length' "$WORK/snapshot.json") || return 1
    if [ "$ACTIVE_COUNT" -eq 0 ]; then
        STABLE_IP=''; write_summary idle '没有启用的域名。' || return 1
        return 0
    fi
    if ! check_api_cooldown; then
        STABLE_IP=''; write_summary deferred "$API_ERROR" || return 1
        log WARN "$API_ERROR"
        return 1
    fi
    if ! get_stable_ip; then
        log ERROR '无法取得连续两次一致的公网 IPv4；本轮不会修改任何域名。'
        write_summary error '公网 IPv4 探测失败或不稳定。' || :
        return 1
    fi
    printf '%s\n' "$STABLE_IP" > "$STATE_DIR/last-public-ip" || return 1
    jq -c '.records[]|select(.enabled)' "$WORK/snapshot.json" > "$WORK/queue" || return 1
    OK_COUNT=0; FAIL_COUNT=0; UPDATE_COUNT=0
    while IFS= read -r CURRENT_JSON; do
        printf '%s\n' "$CURRENT_JSON" > "$WORK/current" || return 1
        API_ERROR=''; SYNC_KIND=''
        if sync_one; then
            OK_COUNT=$((OK_COUNT + 1))
            [ "$SYNC_KIND" != updated ] || UPDATE_COUNT=$((UPDATE_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            log ERROR "$NAME：${API_ERROR:-本地处理失败}"
            write_state error "${API_ERROR:-本地处理失败}" '' null || :
        fi
    done < "$WORK/queue"
    RESULT_MESSAGE="成功 $OK_COUNT 个（更新 $UPDATE_COUNT 个），失败 $FAIL_COUNT 个，出口 IPv4=$STABLE_IP"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        write_summary partial "$RESULT_MESSAGE" || :
        log WARN "$RESULT_MESSAGE"; return 1
    fi
    write_summary ok "$RESULT_MESSAGE" || return 1
    [ "$UPDATE_COUNT" -eq 0 ] || log INFO "$RESULT_MESSAGE"
}
run_once() {
    check_deps && prepare_dirs || exit 1
    exec 9>"$RUN_LOCK" || exit 1
    if ! flock -n 9; then say '已有同步/配置操作正在执行，本次跳过。'; exit 75; fi
    need_config && new_work || exit 1
    rotate_log || { err '日志轮转失败'; exit 1; }
    cp "$CONFIG_FILE" "$WORK/snapshot.json" || exit 1
    RUN_COUNT=$(jq '[.records[]|select(.enabled)]|length' "$WORK/snapshot.json") || exit 1
    # IP 探测最多约 63 秒；每域名至多 Zone 查询、记录查询、PATCH，共约 75 秒。
    # 加入执行余量，按实际域名数量放大整轮预算；不再固定 90 秒强杀多域名更新。
    RUN_BUDGET=$((90 + 90 * RUN_COUNT))
    timeout -k 5 "$RUN_BUDGET" /bin/sh "$SELF" --worker "$WORK" &
    CHILD=$!
    wait "$CHILD"; RUN_RC=$?
    CHILD=''
    case "$RUN_RC" in
        124|137|143)
            log ERROR "本轮超时或被终止（退出码 $RUN_RC，预算 ${RUN_BUDGET}s）；已完成的更新不会回滚。"
            STABLE_IP=''; write_summary error '本轮超时或被终止；请检查日志，已完成更新不会回滚。' || :
            ;;
    esac
    exit "$RUN_RC"
}

# ---------- 原子写入及旧版迁移：备份上一份配置，绝不 source/eval 旧配置 ----------
atomic_file() (
    AF_DEST=$1; AF_MODE=$2; AF_KIND=${3:-text}
    if [ -d "$AF_DEST" ] || { [ -e "$AF_DEST" ] && [ ! -f "$AF_DEST" ] && [ ! -L "$AF_DEST" ]; }; then
        err "目标不是普通文件，拒绝覆盖：$AF_DEST"; exit 1
    fi
    # 临时文件名固定长度，避免长域名状态文件再拼后缀后超过 NAME_MAX。
    AF_PARENT=${AF_DEST%/*}
    [ "$AF_PARENT" != "$AF_DEST" ] || AF_PARENT='.'
    AF_TMP=$(mktemp "$AF_PARENT/.cf-ddns.tmp.XXXXXXXX") || exit 1
    trap 'rm -f -- "$AF_TMP"' 0
    cat > "$AF_TMP" || exit 1
    [ -s "$AF_TMP" ] || exit 1
    if [ "$AF_KIND" = sh ]; then sh -n "$AF_TMP" || exit 1; fi
    chmod "$AF_MODE" "$AF_TMP" && mv -fT "$AF_TMP" "$AF_DEST"
)
commit_config() {
    valid_config "$1" || { err '新配置校验失败，原配置未覆盖。'; return 1; }
    if [ -f "$CONFIG_FILE" ]; then
        atomic_file "$CONFIG_FILE.bak" 600 < "$CONFIG_FILE" || return 1
    fi
    atomic_file "$CONFIG_FILE" 600 < "$1"
}
stage_legacy_config() {
    LEGACY_TOKEN=$(sed -n "s/^CF_API_TOKEN='\([A-Za-z0-9_-]*\)'$/\1/p" "$LEGACY_CONFIG") || return 1
    valid_token "$LEGACY_TOKEN" || { err '旧版 Token 格式无法识别；原配置保留，请勿删除。'; return 1; }
    printf '%s' "$LEGACY_TOKEN" > "$WORK/token" || return 1
    unset LEGACY_TOKEN
    ZONE=$(sed -n "s/^ZONE_NAME='\([^']*\)'$/\1/p" "$LEGACY_CONFIG")
    NAME=$(sed -n "s/^RECORD_NAME='\([^']*\)'$/\1/p" "$LEGACY_CONFIG")
    ZONE=$(normalize_domain "$ZONE"); NAME=$(normalize_domain "$NAME")
    valid_domain "$ZONE" && valid_domain "$NAME" && belongs_to_zone "$NAME" "$ZONE" || {
        err '旧版域名格式/归属校验失败；请检查原配置。'; return 1;
    }
    jq -n --arg z "$ZONE" --arg n "$NAME" --rawfile t "$WORK/token" \
        '{version:2,interval:30,records:[{name:$n,zone:$z,token:$t,zone_id:"",enabled:true}]}' \
        > "$WORK/config.next" || return 1
}
init_config() {
    if [ -f "$CONFIG_FILE" ]; then need_config; return $?; fi
    if [ -f "$LEGACY_CONFIG" ]; then
        say '发现旧版单域名配置，正在安全迁移...'
        stage_legacy_config || return 1
        commit_config "$WORK/config.next" || return 1
        chmod 600 "$LEGACY_CONFIG" && mv -fT "$LEGACY_CONFIG" "$LEGACY_CONFIG.bak" || return 1
        say "已迁移：$NAME；旧配置备份：$LEGACY_CONFIG.bak"
    else
        printf '%s\n' '{"version":2,"interval":30,"records":[]}' > "$WORK/config.next" || return 1
        commit_config "$WORK/config.next" || return 1
    fi
}
manage_begin() {
    prepare_dirs && new_work || return 1
    exec 8>"$MANAGE_LOCK" || return 1
    flock -n 8 || { err '另一项菜单修改正在执行，请结束后重试。'; return 1; }
}

# ---------- 服务文件：systemd 按结束后间隔调度；OpenRC 循环使用同一间隔 ----------
write_timer() {
    TIMER_INTERVAL=$(jq -r '.interval' "$CONFIG_FILE") || return 1
    atomic_file "$TIMER" 644 <<EOF
[Unit]
Description=Cloudflare multi-domain DDNS timer

[Timer]
OnActiveSec=5s
OnUnitInactiveSec=${TIMER_INTERVAL}s
AccuracySec=1s
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF
}
write_services() {
    if [ "$INIT" = systemd ]; then
        atomic_file "$SERVICE" 644 <<EOF
[Unit]
Description=Cloudflare multi-domain DDNS updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNTIME
TimeoutStartSec=infinity
TimeoutStopSec=20s
KillMode=control-group
SuccessExitStatus=75
User=root
UMask=0077
EOF
        [ "$?" -eq 0 ] || return 1
        write_timer || return 1
        systemctl daemon-reload || return 1
    else
        atomic_file "$OPENRC_SERVICE" 755 sh <<EOF
#!/sbin/openrc-run
name="cf-ddns"
description="Cloudflare multi-domain DDNS updater"
command="$LOOP"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
retry="TERM/20/KILL/5"
required_files="$CONFIG_FILE"
umask="0077"
depend() {
    need net
}
EOF
        [ "$?" -eq 0 ] || return 1
    fi
}
install_programs() {
    PROGRAM_SOURCE=${INSTALL_SOURCE:-$SELF}
    valid_script_source "$PROGRAM_SOURCE" || { err '安装源校验失败，拒绝安装不完整的程序。'; return 1; }
    mkdir -p /usr/local/sbin || return 1
    atomic_file "$MANAGER" 755 sh < "$PROGRAM_SOURCE" || return 1
    atomic_file "$RUNTIME" 755 sh <<EOF
#!/bin/sh
exec "$MANAGER" --run
EOF
    [ "$?" -eq 0 ] || return 1
    # 不再创建指向被覆盖文件的软链接；统一使用独立入口。
    atomic_file "$COMPAT" 700 sh <<EOF
#!/bin/sh
exec "$MANAGER" --run
EOF
    [ "$?" -eq 0 ] || return 1
    atomic_file "$LOOP" 755 sh <<EOF
#!/bin/sh
exec "$MANAGER" --loop
EOF
}
openrc_disable_autostart() {
    rc-update show default > "$WORK/openrc-levels" || { err '读取 OpenRC 自启动状态失败。'; return 1; }
    if awk '$1=="cf-ddns" {found=1} END {exit !found}' "$WORK/openrc-levels"; then
        rc-update del cf-ddns default || { err 'OpenRC 取消开机启动失败；服务可能在重启后再次启动。'; return 1; }
        rc-update show default > "$WORK/openrc-levels" || return 1
        if awk '$1=="cf-ddns" {found=1} END {exit !found}' "$WORK/openrc-levels"; then
            err 'OpenRC 仍保留 cf-ddns 自启动项。'; return 1
        fi
    fi
    return 0
}
stop_schedule() {
    if [ "$INIT" = systemd ]; then
        if [ -f "$TIMER" ]; then
            systemctl disable --now cf-ddns.timer || return 1
        fi
        if [ -f "$SERVICE" ]; then
            systemctl stop cf-ddns.service || return 1
            # 兼容旧版把 service 本身设成开机启动的安装方式。
            systemctl disable cf-ddns.service >/dev/null 2>&1 || :
        fi
    else
        if [ -f "$OPENRC_SERVICE" ]; then
            if rc-service cf-ddns status >/dev/null 2>&1; then rc-service cf-ddns stop || return 1; fi
            openrc_disable_autostart || return 1
        fi
    fi
}
start_schedule() (
    # 不让新守护进程继承菜单/运行锁，否则可能永久占住管理锁。
    exec 8>&- 9>&-
    if [ "$INIT" = systemd ]; then
        systemctl daemon-reload && systemctl enable --now cf-ddns.timer &&
            systemctl is-active --quiet cf-ddns.timer
    else
        rc-update add cf-ddns default && rc-service cf-ddns start && rc-service cf-ddns status
    fi
)
remove_legacy_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    if ! crontab -l > "$WORK/cron.old" 2> "$WORK/cron.err"; then
        # Vixie/Cronie 与 BusyBox 对“root 尚无 crontab”的提示不同。
        # 只识别这两种明确的缺失提示，不吞权限、I/O 或其他读取故障。
        if [ ! -s "$WORK/cron.old" ] && grep -Eq \
            "(^|: )no crontab for root$|(^|: )can't open 'root': No such file or directory$" "$WORK/cron.err"; then
            return 0
        fi
        err '读取 root crontab 失败；为避免重复调度，已停止安装/卸载。'
        cat "$WORK/cron.err" >&2
        return 1
    fi
    awk '/^[[:space:]]*#/ {print; next}
         /\/root\/cf_ddns\.sh([[:space:];]|$)/ {next}
         /\/usr\/local\/sbin\/cloudflare-ddns-update([[:space:];]|$)/ {next}
         {print}' "$WORK/cron.old" > "$WORK/cron.new" || return 1
    if ! cmp -s "$WORK/cron.old" "$WORK/cron.new"; then
        cp "$WORK/cron.old" "$CONFIG_DIR/root-crontab.before-ddns" || return 1
        crontab "$WORK/cron.new" || return 1
    fi
}
install_all() (
    detect_init && install_deps && manage_begin || exit 1
    stage_install_source || exit 1
    # 先确认安装源与原配置可用，再停止原调度。
    if [ -f "$CONFIG_FILE" ]; then
        need_config || exit 1
    elif [ -f "$LEGACY_CONFIG" ]; then
        stage_legacy_config || { err '旧配置预检失败，原调度保持不变。'; exit 1; }
    fi
    stop_schedule || { err '停止旧服务失败，未覆盖程序。'; exit 1; }
    remove_legacy_cron || exit 1
    exec 9>"$RUN_LOCK" || exit 1
    flock -w 30 9 || { err '旧任务尚未退出；调度已停止，请稍后重新选择安装。'; exit 1; }
    init_config && install_programs && write_services || {
        err '安装未完成，未报告成功；配置/备份已保留。请检查上方错误后重试。'; exit 1;
    }
    # 由程序自行轮转日志，清理旧 logrotate 配置，避免两种轮转同时操作。
    rm -f "$OLD_LOGROTATE" || exit 1
    flock -u 9; exec 9>&-
    start_schedule || { err '文件已安装，但定时服务启动失败。请查看服务状态，不是安装成功。'; exit 1; }
    say "DDNS 程序已安装：$MANAGER"
    say '调度已启动；首次同步结果请查看状态，服务启动不等于 DNS 更新成功。'
    if [ "$(jq '.records|length' "$CONFIG_FILE")" -eq 0 ]; then
        say '当前没有域名：返回菜单选择 2，可连续添加多个域名。'
    fi
)
loop_main() {
    check_deps && prepare_dirs || return 1
    exec 7>"$LOOP_LOCK" || return 1
    flock -n 7 || { err '已有 OpenRC 循环运行。'; return 1; }
    set_cleanup
    while :; do
        "$RUNTIME" & CHILD=$!
        wait "$CHILD" || :
        CHILD=''
        if valid_config "$CONFIG_FILE"; then LOOP_INTERVAL=$(jq -r '.interval' "$CONFIG_FILE"); else LOOP_INTERVAL=30; fi
        sleep "$LOOP_INTERVAL" & CHILD=$!
        wait "$CHILD" || :
        CHILD=''
    done
}

# ---------- 域名管理：支持同 Token 连续添加，也可选择已有域名的 Token ----------
list_domains() {
    need_config || return 1
    DOMAIN_TOTAL=$(jq '.records|length' "$CONFIG_FILE") || return 1
    [ "$DOMAIN_TOTAL" -ne 0 ] || { say '当前未添加任何域名。'; return 0; }
    printf '\n序号  启用状态  完整域名 / Zone\n'
    jq -r '.records|to_entries[]|"\(.key+1).   \(if .value.enabled then "启用" else "停用" end)    \(.value.name) / \(.value.zone)"' "$CONFIG_FILE"
}
select_domain() {
    list_domains || return 1
    [ "$DOMAIN_TOTAL" -gt 0 ] || return 1
    ask '输入域名序号（回车取消）：' || return 1
    case "$REPLY" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#REPLY}" -le 8 ] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$DOMAIN_TOTAL" ] || { err '序号不正确。'; return 1; }
    SELECT_INDEX=$((REPLY - 1))
    SELECT_NAME=$(jq -r --argjson i "$SELECT_INDEX" '.records[$i].name' "$CONFIG_FILE")
}
choose_token() {
    list_domains || return 1
    say 'Token 需要对应 Zone 的 Zone:Read 和 DNS:Edit 权限。'
    ask '复用哪个域名的 Token？输入序号；直接回车则输入新 Token：' || return 1
    if [ -z "$REPLY" ]; then read_token; return $?; fi
    case "$REPLY" in *[!0-9]*|0*) err '序号不正确。'; return 1 ;; esac
    [ "${#REPLY}" -le 8 ] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$DOMAIN_TOTAL" ] || { err '序号不正确。'; return 1; }
    TOKEN_INDEX=$((REPLY - 1))
    jq -jr --argjson i "$TOKEN_INDEX" '.records[$i].token' "$CONFIG_FILE" > "$WORK/token"
}
create_record_interactive() {
    say "$NAME 尚无 A 记录。"
    ask '现在在 Cloudflare 创建一条灰云 A 记录吗？[y/N]：' || return 1
    case "$REPLY" in y|Y) ;; *) say '未创建，也未加入 DDNS 列表。'; return 1 ;; esac
    get_stable_ip || { err '无法取得稳定的公网 IPv4，未创建记录。'; return 1; }
    jq -n --arg n "$NAME" --arg ip "$STABLE_IP" \
        '{type:"A",name:$n,content:$ip,ttl:1,proxied:false}' > "$WORK/create" || return 1
    # POST 不盲目重试，避免请求超时但服务端已创建后，再次创建重复记录。
    if ! cf_call POST "/zones/$ZONE_ID/dns_records" "$WORK/create"; then
        err "$API_ERROR"
        say '创建结果可能不确定，请先检查 Cloudflare 后再添加；不会自动重复 POST。'
        return 1
    fi
    jq -e --arg n "$NAME" --arg ip "$STABLE_IP" \
        '.result.type=="A" and .result.name==$n and .result.content==$ip' "$WORK/body" >/dev/null 2>&1 || {
        err '创建响应不完整，请先检查 Cloudflare；本地暂未添加。'; return 1;
    }
    say "已创建灰云 A 记录：$NAME -> $STABLE_IP（TTL 自动）。"
    lookup_record || { err "$API_ERROR"; return 1; }
}
add_domains() (
    need_config && manage_begin && choose_token && make_auth || exit 1
    say 'Zone 填 Cloudflare 控制台里的完整区域名，不要自行只取最后两段。'
    ask 'Cloudflare Zone，例如 example.com（回车取消）：' || exit 1
    ZONE=$(normalize_domain "$REPLY")
    valid_domain "$ZONE" || { err 'Zone 格式不正确；中文域名请使用 Punycode。'; exit 1; }
    lookup_zone || { err "$API_ERROR"; exit 1; }
    # 同一会话固定 Zone/Token；循环中不会回到 Token 输入，可快速添加多个域名。
    ADD_ZONE=$ZONE; ADD_ZONE_ID=$ZONE_ID
    while :; do
        printf '\n当前 Zone：%s\n' "$ADD_ZONE"
        ask '完整域名（@ 表示 Zone 本身；回车结束添加）：' || break
        [ -n "$REPLY" ] || break
        if [ "$REPLY" = '@' ]; then NAME=$ADD_ZONE; else NAME=$(normalize_domain "$REPLY"); fi
        ZONE=$ADD_ZONE; ZONE_ID=$ADD_ZONE_ID
        if ! valid_domain "$NAME" || ! belongs_to_zone "$NAME" "$ZONE"; then
            err '完整域名格式不正确，或不属于当前 Zone。'; continue
        fi
        if jq -e --arg n "$NAME" '.records|any(.[];.name==$n)' "$CONFIG_FILE" >/dev/null; then
            err "$NAME 已在 DDNS 列表中，不会重复添加。"; continue
        fi
        LOOKUP_RC=0
        lookup_record || LOOKUP_RC=$?
        case "$LOOKUP_RC" in
            0) ;;
            2) create_record_interactive || continue ;;
            *) err "$API_ERROR"; continue ;;
        esac
        say "将把 $NAME 加入本机 DDNS；后续会把其 A 记录更新为本机出口 IPv4。"
        ask '确认添加并启用？[Y/n]：' || break
        case "$REPLY" in n|N) say '已取消本地添加；已在 Cloudflare 创建的记录不会删除。'; continue ;; esac
        jq --arg n "$NAME" --arg z "$ZONE" --arg id "$ZONE_ID" --rawfile t "$WORK/token" \
            '.records += [{name:$n,zone:$z,zone_id:$id,token:$t,enabled:true}]' \
            "$CONFIG_FILE" > "$WORK/config.next" || exit 1
        commit_config "$WORK/config.next" || {
            err '本地配置保存失败；Cloudflare 上已有的记录保持不变。'; exit 1;
        }
        say "已添加：$NAME。下一轮同步生效；可继续输入同 Zone 的其他完整域名。"
    done
    say '添加结束。跨 Zone/跨账户域名再次选择菜单 2 即可。'
)
delete_domain() (
    need_config && manage_begin && select_domain || exit 1
    say "只移除本机 DDNS 管理，不删除 Cloudflare 上的 DNS 记录：$SELECT_NAME"
    ask '确认移除？[y/N]：' || exit 1
    case "$REPLY" in y|Y) ;; *) say '已取消。'; exit 0 ;; esac
    jq --arg n "$SELECT_NAME" '.records |= map(select(.name!=$n))' "$CONFIG_FILE" > "$WORK/config.next" || exit 1
    commit_config "$WORK/config.next" || exit 1
    say '已移除。正在执行的旧一轮可能仍会完成；从下一轮起不再同步。'
)
toggle_domain() (
    need_config && manage_begin && select_domain || exit 1
    jq --arg n "$SELECT_NAME" '.records |= map(if .name==$n then .enabled=(.enabled|not) else . end)' \
        "$CONFIG_FILE" > "$WORK/config.next" || exit 1
    commit_config "$WORK/config.next" || exit 1
    NEW_ENABLED=$(jq -r --arg n "$SELECT_NAME" '.records[]|select(.name==$n)|.enabled' "$CONFIG_FILE")
    say "$SELECT_NAME：enabled=$NEW_ENABLED。下一轮生效；正在执行的旧一轮可能仍会完成。"
)
replace_token() (
    need_config && manage_begin && select_domain && read_token && make_auth || exit 1
    ZONE=$(jq -r --arg n "$SELECT_NAME" '.records[]|select(.name==$n)|.zone' "$CONFIG_FILE") || exit 1
    NAME=$SELECT_NAME
    lookup_zone && lookup_record || { err "$API_ERROR"; exit 1; }
    jq --arg n "$SELECT_NAME" --arg id "$ZONE_ID" --rawfile t "$WORK/token" \
        '.records |= map(if .name==$n then .token=$t | .zone_id=$id else . end)' \
        "$CONFIG_FILE" > "$WORK/config.next" || exit 1
    commit_config "$WORK/config.next" || exit 1
    say '该域名 Token 已更新，下一轮生效；其他域名的 Token 不会联动修改。'
)
change_interval() (
    need_config && manage_begin && detect_init || exit 1
    say "当前间隔：$(jq -r '.interval' "$CONFIG_FILE") 秒（每轮执行结束后再等待）。"
    ask '新间隔，30~86400 秒（回车取消）：' || exit 1
    [ -n "$REPLY" ] || exit 0
    valid_interval "$REPLY" || { err '请输入 30~86400 的整数，不要带前导零。'; exit 1; }
    jq --argjson i "$REPLY" '.interval=$i' "$CONFIG_FILE" > "$WORK/config.next" || exit 1
    commit_config "$WORK/config.next" || exit 1
    if [ "$INIT" = systemd ] && [ -f "$TIMER" ]; then
        WAS_ACTIVE=false
        systemctl is-active --quiet cf-ddns.timer && WAS_ACTIVE=true
        write_timer && systemctl daemon-reload || { err '配置已保存，但定时器刷新失败，请选择安装/更新。'; exit 1; }
        if [ "$WAS_ACTIVE" = true ]; then systemctl restart cf-ddns.timer || { err '重启定时器失败。'; exit 1; }; fi
    fi
    say '检查间隔已修改；暂停状态不变。OpenRC 在当前轮次/等待结束后读取新间隔。'
)

# ---------- 状态、手动同步、全局启停及卸载 ----------
view_status() {
    need_config || return 1
    say "Cloudflare 多域名 DDNS v$VERSION"
    say "检查间隔：$(jq -r '.interval' "$CONFIG_FILE") 秒（每轮结束后等待）"
    if detect_init 2>/dev/null; then
        if [ "$INIT" = systemd ]; then
            systemctl status cf-ddns.timer --no-pager || :
            say '最近一次服务结果（oneshot 执行结束后 inactive/dead 属正常现象）：'
            systemctl show cf-ddns.service -p ActiveState -p Result -p ExecMainStatus --no-pager || :
        else
            rc-service cf-ddns status || :
        fi
    else
        say '当前环境无法查询 systemd/OpenRC 状态。'
    fi
    if [ -f "$STATE_DIR/last-run.json" ]; then
        jq -r '"\n最近轮次：\(.checked_at)\n轮次状态：\(.status)\n轮次结果：\(.message)\n本轮出口：\(.public_ipv4 // "")"' "$STATE_DIR/last-run.json" || :
    fi
    list_domains || return 1
    jq -r '.records[].name' "$CONFIG_FILE" | while IFS= read -r STATUS_NAME; do
        STATUS_PATH=$(record_state_path "$STATUS_NAME") || return 1
        if [ -r "$STATUS_PATH" ]; then
            jq -r '"\n域名：\(.name)\n  最近检查：\(.checked_at)\n  最近更新：\(.updated_at)\n  最近状态：\(.status)\n  API 地址：\(.cloudflare_ip)\n  说明：\(.message)"' \
                "$STATUS_PATH" || :
        else
            printf '\n域名：%s\n  暂无同步结果。\n' "$STATUS_NAME"
        fi
    done
    say '注：域名状态是该域名最近一次实际检查结果；本轮探测失败时应以轮次结果为准。'
}
view_logs() { tail -n 80 "$LOG_FILE" 2>/dev/null || say '暂无日志。'; }
manual_check() {
    [ -x "$RUNTIME" ] || { err '请先安装。'; return 1; }
    "$RUNTIME"; MANUAL_RC=$?
    case "$MANUAL_RC" in
        0) say '本轮执行完成，下面显示实际结果。' ;;
        75) say '已有任务执行，本次未重复启动。' ;;
        *) err "本轮存在失败（退出码 $MANUAL_RC），请查看各域名状态与日志。" ;;
    esac
    view_status
    return "$MANUAL_RC"
}
toggle_schedule() (
    need_config && manage_begin && detect_init || exit 1
    if [ "$INIT" = systemd ]; then
        if systemctl is-active --quiet cf-ddns.timer; then SCHEDULE_ACTIVE=true; else SCHEDULE_ACTIVE=false; fi
    else
        if rc-service cf-ddns status >/dev/null 2>&1; then SCHEDULE_ACTIVE=true; else SCHEDULE_ACTIVE=false; fi
    fi
    if [ "$SCHEDULE_ACTIVE" = true ]; then
        stop_schedule || { err '自动同步停止失败。'; exit 1; }
        say '已暂停自动同步并取消其开机启动；所有域名配置和 Cloudflare 记录保留。'
    else
        [ -x "$RUNTIME" ] || { err '程序未安装完整，请先选择安装/更新。'; exit 1; }
        start_schedule || { err '自动同步启动失败，请检查服务状态。'; exit 1; }
        say '自动同步已恢复并启用开机启动；实际更新结果请查看状态。'
    fi
)
uninstall_all() (
    check_deps && manage_begin && detect_init || exit 1
    say '将停止自动同步，删除本机程序、Token 配置/备份、状态与日志；不会删除 Cloudflare DNS 记录。'
    ask '确认卸载？请输入 DELETE：' || exit 1
    [ "$REPLY" = DELETE ] || { say '已取消，返回菜单。'; exit 2; }
    stop_schedule && remove_legacy_cron || exit 1
    exec 9>"$RUN_LOCK" || exit 1
    flock -w 30 9 || { err '还有手动/旧任务运行，未删除文件；请结束任务后重试。'; exit 1; }
    rm -f "$TIMER" "$SERVICE" "$OPENRC_SERVICE" "$LOOP" "$RUNTIME" "$COMPAT" "$MANAGER" "$OLD_LOGROTATE" || exit 1
    rm -f "$LEGACY_CONFIG" "$LEGACY_CONFIG.bak" "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2" \
        "$LOG_FILE.3" "$LOG_FILE.4" "$LOG_FILE.5" || exit 1
    rm -rf "$CONFIG_DIR" "$STATE_DIR" || exit 1
    if [ "$INIT" = systemd ]; then systemctl daemon-reload || exit 1; fi
    # 不删除运行中的锁文件，避免并发进程锁到不同 inode。/run 下锁在重启后自然清理。
    say '本机 DDNS 已卸载，Cloudflare 上的 DNS 记录未删除。'
    say '你自行保存的下载脚本/外部备份，以及系统日志中的历史记录不在自动删除范围内。'
)

main_menu() {
    while :; do
        printf '\n====================================================\n'
        printf '  Cloudflare 多域名 DDNS 管理 v%s\n' "$VERSION"
        printf '====================================================\n'
        printf '  1. 安装 / 更新 DDNS（保留配置；迁移原单域名）\n'
        printf '  2. 添加域名（可连续添加多个）\n'
        printf '  3. 查看域名列表\n'
        printf '  4. 删除一个域名（仅移除本机管理）\n'
        printf '  5. 启用 / 停用一个域名\n'
        printf '  6. 更换一个域名的 API Token\n'
        printf '  7. 查看服务与各域名状态\n'
        printf '  8. 查看运行日志\n'
        printf '  9. 立即检测并同步全部启用域名\n'
        printf ' 10. 修改检查间隔\n'
        printf ' 11. 暂停 / 恢复全部自动同步\n'
        printf ' 12. 卸载 DDNS\n'
        printf '  0. 退出\n'
        ask '请选择 [0-12]：' || break
        case "$REPLY" in
            1) install_all; pause ;;
            2) add_domains; pause ;;
            3) list_domains; pause ;;
            4) delete_domain; pause ;;
            5) toggle_domain; pause ;;
            6) replace_token; pause ;;
            7) view_status; pause ;;
            8) view_logs; pause ;;
            9) manual_check; pause ;;
            10) change_interval; pause ;;
            11) toggle_schedule; pause ;;
            12) uninstall_all && break; pause ;;
            0) break ;;
            *) err '无效选项。' ;;
        esac
    done
}

# ---------- 命令入口 ----------
main() {
    [ "$(id -u)" -eq 0 ] || { err '请使用 root 运行。'; return 1; }
    case "$0" in
        /*) SELF=$0 ;;
        */*) SELF="$(pwd)/$0" ;;
        *) SELF=$(command -v "$0" 2>/dev/null) || SELF="$(pwd)/$0" ;;
    esac
    case "$0" in
        /dev/fd/*|/proc/*/fd/*) SOURCE_KIND=fd ;;
        sh|bash|dash|ash|-sh|-bash|-dash|-ash|/bin/sh|/bin/bash|/bin/dash|/bin/ash|/usr/bin/sh|/usr/bin/bash|/usr/bin/dash|/usr/bin/ash)
            SOURCE_KIND=stdin ;;
        *) if [ -p "$SELF" ]; then SOURCE_KIND=fd; fi ;;
    esac
    if [ "$SOURCE_KIND" != file ]; then
        bootstrap_stream "$@"
        return $?
    fi
    case "${1:---menu}" in
        --menu) main_menu ;;
        --run) run_once ;;
        --worker) [ "$#" -eq 2 ] && sync_worker "$2" ;;
        --loop) loop_main ;;
        --status) view_status ;;
        --logs) view_logs ;;
        --version) say "$VERSION" ;;
        --help|-h)
            say '用法：cloudflare-ddns [--menu|--run|--status|--logs|--version]'
            say '支持本地文件执行或 GitHub bash <(curl -fsSL URL)；管道菜单需要可用终端。'
            ;;
        *) err '未知参数，请使用 --help。'; return 2 ;;
    esac
}
main "$@"
# CF_DDNS_SOURCE_END 2.0.2
