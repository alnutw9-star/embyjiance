#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/config.conf"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# =========================================================
# 默认配置兜底
# =========================================================
: "${WORK_DIR:=$SCRIPT_DIR}"
: "${LOG_DIR:=${WORK_DIR}/logs}"
: "${RUN_DIR:=${WORK_DIR}/run}"
: "${TMP_DIR:=${WORK_DIR}/tmp}"

: "${LOG_MAX_SIZE_MB:=50}"
: "${LOG_KEEP_FILES:=10}"
: "${DEBUG_LOG_ENABLE:=false}"
: "${DEBUG_HEALTH_LOG_INTERVAL:=1800}"

: "${SERVICE_NAME:=emby-server}"
: "${PRO189_CONTAINER_NAME:=cloud189pro}"

: "${EMBY_SCHEME:=http}"
: "${EMBY_HOST:=127.0.0.1}"
: "${EMBY_PORT:=8096}"
: "${EMBY_HEALTH_PATH:=/emby/System/Info/Public}"
: "${EMBY_HTTP_EXPECTED_CODE:=200}"
: "${EMBY_BODY_REQUIRED_REGEX:=\"(Version|ServerName|ProductName|OperatingSystem)\"}"

: "${PRO189_SCHEME:=http}"
: "${PRO189_HOST:=127.0.0.1}"
: "${PRO189_PORT:=8091}"
: "${PRO189_HEALTH_PATH:=/}"
: "${PRO189_HTTP_EXPECTED_CODE_REGEX:=^(200|204|301|302|401|403)$}"
: "${PRO189_BODY_CHECK_ENABLE:=false}"
: "${PRO189_BODY_REQUIRED_REGEX:=.}"

: "${CHECK_INTERVAL:=15}"
: "${RETRY_INTERVAL:=5}"
: "${RECOVERY_POLL_INTERVAL:=5}"
: "${FORCE_KILL_WAIT:=3}"
: "${COOLDOWN_AFTER_RECOVERY:=5}"

: "${EMBY_MAX_FAILURES:=3}"
: "${PRO189_MAX_FAILURES:=3}"
: "${EMBY_RECOVERY_WAIT_AFTER_RESTART:=180}"
: "${EMBY_RECOVERY_WAIT_AFTER_FORCE_START:=300}"
: "${PRO189_RECOVERY_WAIT_AFTER_RESTART:=90}"
: "${PRO189_RECOVERY_WAIT_AFTER_FORCE_START:=120}"

: "${BREAKER_WINDOW_SECONDS:=1800}"
: "${BREAKER_HOLD_SECONDS:=3600}"
: "${BREAKER_AUTO_RELEASE:=true}"
: "${EMBY_BREAKER_MAX_RESTARTS:=3}"
: "${PRO189_BREAKER_MAX_RESTARTS:=3}"

: "${HEARTBEAT_LOG_INTERVAL:=3600}"

: "${ENABLE_TG_NOTIFY:=false}"
: "${TG_BOT_TOKEN:=}"
: "${TG_CHAT_ID:=}"
: "${TG_ALLOW_CHAT_IDS:=}"
: "${TG_ALLOW_USER_IDS:=}"
: "${TG_PROXY:=}"
: "${TG_REQUEST_TIMEOUT:=20}"
: "${TG_POLL_TIMEOUT:=25}"
: "${TG_PREFIX:=}"
: "${TG_NOTIFY_WARNING:=true}"
: "${TG_NOTIFY_RECOVERY_START:=true}"
: "${TG_NOTIFY_RECOVERY_SUCCESS:=true}"
: "${TG_NOTIFY_RECOVERY_FAILURE:=true}"
: "${TG_NOTIFY_BREAKER:=true}"
: "${TG_NOTIFY_SCRIPT_START:=true}"
: "${TG_NOTIFY_SCRIPT_STOP:=true}"
: "${TG_NOTIFY_STATUS_HEARTBEAT:=false}"
: "${TG_STATUS_HEARTBEAT_INTERVAL:=43200}"
: "${TG_WARNING_MIN_GAP:=300}"
: "${TG_FAILURE_MIN_GAP:=300}"

: "${GUARD_PAUSE_FILE:=${RUN_DIR}/guard.pause}"

# =========================================================
# 全局路径
# =========================================================
LOG_FILE="${LOG_DIR}/guard.log"
DEBUG_LOG_FILE="${LOG_DIR}/debug.log"
TG_LOG_FILE="${LOG_DIR}/telegram.log"
CONTROL_LOG_FILE="${LOG_DIR}/tg_control.log"
ACTION_LOG_FILE="${LOG_DIR}/actions.log"

STATE_FILE="${RUN_DIR}/guard.state"
TG_STATE_FILE="${RUN_DIR}/tg_control.state"
ACTION_LOCK_FILE="${RUN_DIR}/action.lock"
MAIN_LOCK_FILE="${RUN_DIR}/guard.lock"
TG_LOCK_FILE="${RUN_DIR}/tg_control.lock"

EMBY_HISTORY_FILE="${RUN_DIR}/emby_restart_history.log"
PRO189_HISTORY_FILE="${RUN_DIR}/pro189_restart_history.log"
EMBY_BREAKER_FILE="${RUN_DIR}/emby_breaker.state"
PRO189_BREAKER_FILE="${RUN_DIR}/pro189_breaker.state"

START_EPOCH="$(date +%s)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PRIMARY_IP="${PRIMARY_IP:-unknown}"

# =========================================================
# 运行时变量
# =========================================================
EMBY_OK=0
EMBY_REASON="未检查"
EMBY_SERVICE_STATE="unknown"
EMBY_SUBSTATE="unknown"
EMBY_PID="unknown"
EMBY_RESULT_STATE="unknown"
EMBY_PORT_STATE="unknown"
EMBY_HTTP_CODE="000"
EMBY_HTTP_TIME="0"
EMBY_HTTP_SIZE="0"
EMBY_CURL_ERR=""
EMBY_CURL_RC="0"
EMBY_BODY_VALID="no"
EMBY_BODY_SNIPPET=""

PRO189_OK=0
PRO189_REASON="未检查"
PRO189_CONTAINER_EXISTS="unknown"
PRO189_CONTAINER_RUNNING="unknown"
PRO189_CONTAINER_HEALTH="unknown"
PRO189_PORT_STATE="unknown"
PRO189_HTTP_CODE="000"
PRO189_HTTP_TIME="0"
PRO189_HTTP_SIZE="0"
PRO189_CURL_ERR=""
PRO189_CURL_RC="0"
PRO189_BODY_VALID="skip"
PRO189_BODY_SNIPPET=""

EMBY_FAIL_COUNT=0
PRO189_FAIL_COUNT=0
EMBY_TOTAL_RESTARTS=0
PRO189_TOTAL_RESTARTS=0

# 兼容旧变量
LAST_WARNING_NOTIFY_EPOCH=0
LAST_FAILURE_NOTIFY_EPOCH=0

# 新的分服务通知节流
LAST_EMBY_WARNING_NOTIFY_EPOCH=0
LAST_PRO189_WARNING_NOTIFY_EPOCH=0
LAST_EMBY_FAILURE_NOTIFY_EPOCH=0
LAST_PRO189_FAILURE_NOTIFY_EPOCH=0

LAST_HEARTBEAT_LOG_EPOCH=0
LAST_HEARTBEAT_TG_EPOCH=0
LAST_DEBUG_HEALTH_LOG_EPOCH=0

EMBY_BREAKER_ACTIVE=0
EMBY_BREAKER_START_EPOCH=0
EMBY_BREAKER_UNTIL_EPOCH=0
PRO189_BREAKER_ACTIVE=0
PRO189_BREAKER_START_EPOCH=0
PRO189_BREAKER_UNTIL_EPOCH=0

ACTION_LOCK_FD=""
ACTION_LOCK_HELD=0

# =========================================================
# 基础工具
# =========================================================
now_epoch() { date +%s; }
now_beijing() { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }

is_true() {
    local v="${1:-}"
    v="${v,,}"
    [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

safe_mkdir() { mkdir -p "$1"; }

ensure_dirs() {
    safe_mkdir "$WORK_DIR"
    safe_mkdir "$LOG_DIR"
    safe_mkdir "$RUN_DIR"
    safe_mkdir "$TMP_DIR"
    touch "$LOG_FILE" "$DEBUG_LOG_FILE" "$TG_LOG_FILE" "$CONTROL_LOG_FILE" "$ACTION_LOG_FILE"
    touch "$EMBY_HISTORY_FILE" "$PRO189_HISTORY_FILE"
}

rotate_one_log() {
    local file="$1"
    local max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
    local size i

    [ -f "$file" ] || return 0

    size=$(wc -c < "$file" 2>/dev/null || echo 0)
    size="${size//[[:space:]]/}"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    if (( size < max_bytes )); then
        return 0
    fi

    [ -f "${file}.${LOG_KEEP_FILES}" ] && rm -f "${file}.${LOG_KEEP_FILES}"

    for (( i=LOG_KEEP_FILES-1; i>=1; i-- )); do
        [ -f "${file}.${i}" ] && mv -f "${file}.${i}" "${file}.$((i+1))"
    done

    mv -f "$file" "${file}.1"
    : > "$file"
}

rotate_logs() {
    rotate_one_log "$LOG_FILE"
    rotate_one_log "$DEBUG_LOG_FILE"
    rotate_one_log "$TG_LOG_FILE"
    rotate_one_log "$CONTROL_LOG_FILE"
    rotate_one_log "$ACTION_LOG_FILE"
}

write_log() {
    local file="$1"
    local level="$2"
    local msg="$3"
    rotate_logs
    printf '[%s] [%s] %s\n' "$(now_beijing)" "$level" "$msg" >> "$file"
}

log_main()   { write_log "$LOG_FILE" "$1" "$2"; }
log_debug()  { if is_true "$DEBUG_LOG_ENABLE"; then write_log "$DEBUG_LOG_FILE" "$1" "$2"; fi; }
log_tg()     { write_log "$TG_LOG_FILE" "$1" "$2"; }
log_ctrl()   { write_log "$CONTROL_LOG_FILE" "$1" "$2"; }
log_action() { write_log "$ACTION_LOG_FILE" "$1" "$2"; }

require_commands() {
    local missing=()
    local required=(curl systemctl docker ss awk sed grep flock date hostname wc mv rm mkdir tr head tail mktemp python3)
    local cmd

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        printf '缺少命令: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

human_duration() {
    local total="${1:-0}"
    local d h m s

    d=$(( total / 86400 ))
    h=$(( (total % 86400) / 3600 ))
    m=$(( (total % 3600) / 60 ))
    s=$(( total % 60 ))

    if (( d > 0 )); then
        printf '%d天%02d时%02d分%02d秒' "$d" "$h" "$m" "$s"
    elif (( h > 0 )); then
        printf '%d时%02d分%02d秒' "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf '%d分%02d秒' "$m" "$s"
    else
        printf '%d秒' "$s"
    fi
}

truncate_text() {
    local text="${1:-}"
    local max_len="${2:-300}"

    if (( ${#text} > max_len )); then
        printf '%s...(已截断)' "${text:0:max_len}"
    else
        printf '%s' "$text"
    fi
}

body_compact_snippet() {
    local file="$1"
    if [ -s "$file" ]; then
        tr '\r\n' ' ' < "$file" | sed 's/[[:space:]]\+/ /g' | head -c 220
    else
        printf ''
    fi
}

# 安全执行命令：既拿到 rc，又不让 set -e 直接打断流程
run_quiet() {
    set +e
    "$@" >/dev/null 2>&1
    local rc=$?
    set -e
    return "$rc"
}

# =========================================================
# 状态文件
# =========================================================
load_guard_state() {
    [ -f "$STATE_FILE" ] || return 0

    local legacy_warn=0 legacy_fail=0

    while IFS='=' read -r key val; do
        case "$key" in
            EMBY_FAIL_COUNT|PRO189_FAIL_COUNT|EMBY_TOTAL_RESTARTS|PRO189_TOTAL_RESTARTS|LAST_HEARTBEAT_LOG_EPOCH|LAST_HEARTBEAT_TG_EPOCH|LAST_DEBUG_HEALTH_LOG_EPOCH|LAST_EMBY_WARNING_NOTIFY_EPOCH|LAST_PRO189_WARNING_NOTIFY_EPOCH|LAST_EMBY_FAILURE_NOTIFY_EPOCH|LAST_PRO189_FAILURE_NOTIFY_EPOCH|LAST_WARNING_NOTIFY_EPOCH|LAST_FAILURE_NOTIFY_EPOCH)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    printf -v "$key" '%s' "$val"
                fi
                ;;
        esac
    done < "$STATE_FILE"

    legacy_warn="${LAST_WARNING_NOTIFY_EPOCH:-0}"
    legacy_fail="${LAST_FAILURE_NOTIFY_EPOCH:-0}"

    if (( LAST_EMBY_WARNING_NOTIFY_EPOCH == 0 )) && (( legacy_warn > 0 )); then
        LAST_EMBY_WARNING_NOTIFY_EPOCH="$legacy_warn"
    fi
    if (( LAST_PRO189_WARNING_NOTIFY_EPOCH == 0 )) && (( legacy_warn > 0 )); then
        LAST_PRO189_WARNING_NOTIFY_EPOCH="$legacy_warn"
    fi
    if (( LAST_EMBY_FAILURE_NOTIFY_EPOCH == 0 )) && (( legacy_fail > 0 )); then
        LAST_EMBY_FAILURE_NOTIFY_EPOCH="$legacy_fail"
    fi
    if (( LAST_PRO189_FAILURE_NOTIFY_EPOCH == 0 )) && (( legacy_fail > 0 )); then
        LAST_PRO189_FAILURE_NOTIFY_EPOCH="$legacy_fail"
    fi
}

save_guard_state() {
    cat > "$STATE_FILE" <<EOF_STATE
EMBY_FAIL_COUNT=${EMBY_FAIL_COUNT}
PRO189_FAIL_COUNT=${PRO189_FAIL_COUNT}
EMBY_TOTAL_RESTARTS=${EMBY_TOTAL_RESTARTS}
PRO189_TOTAL_RESTARTS=${PRO189_TOTAL_RESTARTS}
LAST_EMBY_WARNING_NOTIFY_EPOCH=${LAST_EMBY_WARNING_NOTIFY_EPOCH}
LAST_PRO189_WARNING_NOTIFY_EPOCH=${LAST_PRO189_WARNING_NOTIFY_EPOCH}
LAST_EMBY_FAILURE_NOTIFY_EPOCH=${LAST_EMBY_FAILURE_NOTIFY_EPOCH}
LAST_PRO189_FAILURE_NOTIFY_EPOCH=${LAST_PRO189_FAILURE_NOTIFY_EPOCH}
LAST_WARNING_NOTIFY_EPOCH=${LAST_WARNING_NOTIFY_EPOCH}
LAST_FAILURE_NOTIFY_EPOCH=${LAST_FAILURE_NOTIFY_EPOCH}
LAST_HEARTBEAT_LOG_EPOCH=${LAST_HEARTBEAT_LOG_EPOCH}
LAST_HEARTBEAT_TG_EPOCH=${LAST_HEARTBEAT_TG_EPOCH}
LAST_DEBUG_HEALTH_LOG_EPOCH=${LAST_DEBUG_HEALTH_LOG_EPOCH}
EOF_STATE
}

load_breaker_file() {
    local file="$1"
    local prefix="$2"
    [ -f "$file" ] || return 0

    while IFS='=' read -r key val; do
        case "$key" in
            ACTIVE|START_EPOCH|UNTIL_EPOCH)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    printf -v "${prefix}_${key}" '%s' "$val"
                fi
                ;;
        esac
    done < "$file"
}

save_breaker_file() {
    local file="$1"
    local active_var="$2"
    local start_var="$3"
    local until_var="$4"

    cat > "$file" <<EOF_BREAKER
ACTIVE=${!active_var}
START_EPOCH=${!start_var}
UNTIL_EPOCH=${!until_var}
EOF_BREAKER
}

load_breakers() {
    load_breaker_file "$EMBY_BREAKER_FILE" EMBY_BREAKER
    load_breaker_file "$PRO189_BREAKER_FILE" PRO189_BREAKER
}

save_emby_breaker() {
    save_breaker_file "$EMBY_BREAKER_FILE" EMBY_BREAKER_ACTIVE EMBY_BREAKER_START_EPOCH EMBY_BREAKER_UNTIL_EPOCH
}

save_pro189_breaker() {
    save_breaker_file "$PRO189_BREAKER_FILE" PRO189_BREAKER_ACTIVE PRO189_BREAKER_START_EPOCH PRO189_BREAKER_UNTIL_EPOCH
}

# =========================================================
# 锁
# =========================================================
acquire_singleton_lock() {
    local lock_file="$1"
    local desc="$2"
    exec 9>"$lock_file"

    if ! flock -n 9; then
        log_main "ERROR" "检测到已有一个 ${desc} 实例在运行，当前实例退出。"
        exit 1
    fi
}

acquire_action_lock() {
    local actor="${1:-unknown}"

    if (( ACTION_LOCK_HELD == 1 )); then
        return 0
    fi

    exec {ACTION_LOCK_FD}>"$ACTION_LOCK_FILE"
    if flock -n "$ACTION_LOCK_FD"; then
        ACTION_LOCK_HELD=1
        log_action "INFO" "动作锁获取成功：${actor}"
        return 0
    fi

    log_action "WARN" "动作锁获取失败：${actor}，已有任务执行中。"
    return 1
}

release_action_lock() {
    if (( ACTION_LOCK_HELD == 1 )); then
        flock -u "$ACTION_LOCK_FD" || true
        eval "exec ${ACTION_LOCK_FD}>&-" || true
        ACTION_LOCK_HELD=0
        ACTION_LOCK_FD=""
        log_action "INFO" "动作锁已释放"
    fi
}

# =========================================================
# Telegram
# =========================================================
telegram_configured() {
    if ! is_true "$ENABLE_TG_NOTIFY"; then return 1; fi
    [ -n "${TG_BOT_TOKEN:-}" ] || return 1
    [ -n "${TG_CHAT_ID:-}" ] || return 1
    [[ "$TG_BOT_TOKEN" != *"REPLACE_ME"* ]] || return 1
    return 0
}

send_tg_to_chat() {
    local chat_id="$1"
    local title="$2"
    local body="${3:-}"
    local text api_url tmp_err resp rc

    if ! telegram_configured; then
        log_tg "WARN" "TG 未配置完成，跳过发送：${title}"
        return 1
    fi

    text="${TG_PREFIX} ${title}
时间：$(now_beijing)
主机：${HOSTNAME_FQDN} (${PRIMARY_IP})

${body}"
    text="$(truncate_text "$text" 3800)"
    api_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    tmp_err="$(mktemp -p "$TMP_DIR" tg_send_err.XXXXXX)"

    local -a curl_args=(
        -sS
        --connect-timeout 8
        --max-time "$TG_REQUEST_TIMEOUT"
        -X POST
        "$api_url"
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "text=${text}"
        --data "disable_web_page_preview=true"
    )
    [ -n "$TG_PROXY" ] && curl_args+=(--proxy "$TG_PROXY")

    set +e
    resp="$(curl "${curl_args[@]}" 2>"$tmp_err")"
    rc=$?
    set -e

    if (( rc == 0 )) && grep -q '"ok":true' <<< "$resp"; then
        log_tg "INFO" "发送成功 | chat=${chat_id} | ${title}"
        rm -f "$tmp_err"
        return 0
    fi

    log_tg "ERROR" "发送失败 | chat=${chat_id} | ${title} | curl_rc=${rc} | err=$(truncate_text "$(cat "$tmp_err" 2>/dev/null || true)" 220) | resp=$(truncate_text "$resp" 320)"
    rm -f "$tmp_err"
    return 1
}

send_tg_message() {
    send_tg_to_chat "$TG_CHAT_ID" "$1" "${2:-}"
}

# =========================================================
# URL / 状态检查
# =========================================================
emby_url() {
    printf '%s://%s:%s%s' "$EMBY_SCHEME" "$EMBY_HOST" "$EMBY_PORT" "$EMBY_HEALTH_PATH"
}

pro189_url() {
    printf '%s://%s:%s%s' "$PRO189_SCHEME" "$PRO189_HOST" "$PRO189_PORT" "$PRO189_HEALTH_PATH"
}

service_state()   { systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown"; }
service_substate(){ systemctl show "$SERVICE_NAME" -p SubState --value 2>/dev/null || echo "unknown"; }
service_main_pid(){ systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || echo "unknown"; }
service_result()  { systemctl show "$SERVICE_NAME" -p Result --value 2>/dev/null || echo "unknown"; }

perform_http_probe() {
    local url="$1"
    local connect_timeout="$2"
    local max_time="$3"
    local body_file="$4"
    local err_file="$5"

    local response rc
    set +e
    response="$(curl -sS \
        -o "$body_file" \
        -w 'http_code=%{http_code} time_total=%{time_total} size_download=%{size_download}' \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        "$url" 2>"$err_file")"
    rc=$?
    set -e

    printf '%s\n' "$response"
    return "$rc"
}

check_emby_health() {
    local body_file err_file response_line curl_rc

    body_file="$(mktemp -p "$TMP_DIR" emby_body.XXXXXX)"
    err_file="$(mktemp -p "$TMP_DIR" emby_err.XXXXXX)"

    EMBY_SERVICE_STATE="$(service_state)"
    EMBY_SUBSTATE="$(service_substate)"
    EMBY_PID="$(service_main_pid)"
    EMBY_RESULT_STATE="$(service_result)"

    if ss -ltn "( sport = :${EMBY_PORT} )" 2>/dev/null | awk 'NR>1 && $1=="LISTEN"{f=1} END{exit !f}'; then
        EMBY_PORT_STATE="listening"
    else
        EMBY_PORT_STATE="not_listening"
    fi

    response_line="$(perform_http_probe "$(emby_url)" 2 5 "$body_file" "$err_file")"
    curl_rc=$?

    EMBY_CURL_RC="$curl_rc"
    EMBY_CURL_ERR="$(truncate_text "$(cat "$err_file" 2>/dev/null || true)" 220)"
    EMBY_HTTP_CODE="$(awk -F'http_code=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    EMBY_HTTP_TIME="$(awk -F'time_total=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    EMBY_HTTP_SIZE="$(awk -F'size_download=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    EMBY_HTTP_CODE="${EMBY_HTTP_CODE:-000}"
    EMBY_HTTP_TIME="${EMBY_HTTP_TIME:-0}"
    EMBY_HTTP_SIZE="${EMBY_HTTP_SIZE:-0}"
    EMBY_BODY_SNIPPET="$(body_compact_snippet "$body_file")"

    if [ -s "$body_file" ] && grep -Eq "$EMBY_BODY_REQUIRED_REGEX" "$body_file"; then
        EMBY_BODY_VALID="yes"
    else
        EMBY_BODY_VALID="no"
    fi

    EMBY_OK=0
    if [ "$EMBY_SERVICE_STATE" != "active" ]; then
        EMBY_REASON="systemd=${EMBY_SERVICE_STATE}/${EMBY_SUBSTATE}, PID=${EMBY_PID}, Result=${EMBY_RESULT_STATE}"
    elif [ "$EMBY_PORT_STATE" != "listening" ]; then
        EMBY_REASON="端口 ${EMBY_PORT} 未监听"
    elif [ "$EMBY_HTTP_CODE" != "$EMBY_HTTP_EXPECTED_CODE" ]; then
        EMBY_REASON="HTTP状态异常，期望=${EMBY_HTTP_EXPECTED_CODE}，实际=${EMBY_HTTP_CODE}，curl_rc=${EMBY_CURL_RC}，curl=${EMBY_CURL_ERR:-无}"
    elif [ "$EMBY_BODY_VALID" != "yes" ]; then
        EMBY_REASON="返回内容校验失败，疑似错误页或空响应"
    else
        EMBY_OK=1
        EMBY_REASON="健康"
    fi

    log_debug "DEBUG" "Emby健康检查 | ok=${EMBY_OK} | svc=${EMBY_SERVICE_STATE}/${EMBY_SUBSTATE} | pid=${EMBY_PID} | port=${EMBY_PORT_STATE} | http=${EMBY_HTTP_CODE} | curl_rc=${EMBY_CURL_RC} | body=${EMBY_BODY_VALID} | reason=${EMBY_REASON}"
    rm -f "$body_file" "$err_file"
    return 0
}

check_pro189_health() {
    local body_file err_file response_line curl_rc inspect_running inspect_health

    body_file="$(mktemp -p "$TMP_DIR" pro189_body.XXXXXX)"
    err_file="$(mktemp -p "$TMP_DIR" pro189_err.XXXXXX)"

    if docker inspect "$PRO189_CONTAINER_NAME" >/dev/null 2>&1; then
        PRO189_CONTAINER_EXISTS="yes"
        inspect_running="$(docker inspect -f '{{.State.Running}}' "$PRO189_CONTAINER_NAME" 2>/dev/null || echo unknown)"
        inspect_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$PRO189_CONTAINER_NAME" 2>/dev/null || echo unknown)"
        PRO189_CONTAINER_RUNNING="$inspect_running"
        PRO189_CONTAINER_HEALTH="$inspect_health"
    else
        PRO189_CONTAINER_EXISTS="no"
        PRO189_CONTAINER_RUNNING="no"
        PRO189_CONTAINER_HEALTH="unknown"
    fi

    if ss -ltn "( sport = :${PRO189_PORT} )" 2>/dev/null | awk 'NR>1 && $1=="LISTEN"{f=1} END{exit !f}'; then
        PRO189_PORT_STATE="listening"
    else
        PRO189_PORT_STATE="not_listening"
    fi

    response_line="$(perform_http_probe "$(pro189_url)" 2 4 "$body_file" "$err_file")"
    curl_rc=$?

    PRO189_CURL_RC="$curl_rc"
    PRO189_CURL_ERR="$(truncate_text "$(cat "$err_file" 2>/dev/null || true)" 220)"
    PRO189_HTTP_CODE="$(awk -F'http_code=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    PRO189_HTTP_TIME="$(awk -F'time_total=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    PRO189_HTTP_SIZE="$(awk -F'size_download=' '{print $2}' <<< "$response_line" | awk '{print $1}')"
    PRO189_HTTP_CODE="${PRO189_HTTP_CODE:-000}"
    PRO189_HTTP_TIME="${PRO189_HTTP_TIME:-0}"
    PRO189_HTTP_SIZE="${PRO189_HTTP_SIZE:-0}"
    PRO189_BODY_SNIPPET="$(body_compact_snippet "$body_file")"

    if is_true "$PRO189_BODY_CHECK_ENABLE"; then
        if [ -s "$body_file" ] && grep -Eq "$PRO189_BODY_REQUIRED_REGEX" "$body_file"; then
            PRO189_BODY_VALID="yes"
        else
            PRO189_BODY_VALID="no"
        fi
    else
        PRO189_BODY_VALID="skip"
    fi

    PRO189_OK=0
    if [ "$PRO189_CONTAINER_EXISTS" != "yes" ]; then
        PRO189_REASON="容器不存在：${PRO189_CONTAINER_NAME}"
    elif [ "$PRO189_CONTAINER_RUNNING" != "true" ]; then
        PRO189_REASON="容器未运行，running=${PRO189_CONTAINER_RUNNING}"
    elif [ "$PRO189_PORT_STATE" != "listening" ]; then
        PRO189_REASON="端口 ${PRO189_PORT} 未监听"
    elif ! [[ "$PRO189_HTTP_CODE" =~ $PRO189_HTTP_EXPECTED_CODE_REGEX ]]; then
        PRO189_REASON="HTTP状态异常，实际=${PRO189_HTTP_CODE}，curl_rc=${PRO189_CURL_RC}，curl=${PRO189_CURL_ERR:-无}"
    elif is_true "$PRO189_BODY_CHECK_ENABLE" && [ "$PRO189_BODY_VALID" != "yes" ]; then
        PRO189_REASON="返回内容校验失败"
    else
        PRO189_OK=1
        PRO189_REASON="健康"
    fi

    log_debug "DEBUG" "189Pro健康检查 | ok=${PRO189_OK} | exists=${PRO189_CONTAINER_EXISTS} | running=${PRO189_CONTAINER_RUNNING} | health=${PRO189_CONTAINER_HEALTH} | port=${PRO189_PORT_STATE} | http=${PRO189_HTTP_CODE} | curl_rc=${PRO189_CURL_RC} | body=${PRO189_BODY_VALID} | reason=${PRO189_REASON}"
    rm -f "$body_file" "$err_file"
    return 0
}

check_all_health() {
    check_emby_health
    check_pro189_health
    return 0
}

# =========================================================
# 摘要 / 文本
# =========================================================
emby_summary() {
    cat <<EOF_EMBY
一、Emby
- 状态：$( (( EMBY_OK == 1 )) && echo 正常 || echo 异常 )
- 服务名：${SERVICE_NAME}
- systemd：${EMBY_SERVICE_STATE}/${EMBY_SUBSTATE}
- 主进程PID：${EMBY_PID}
- 结果状态：${EMBY_RESULT_STATE}
- 端口：${EMBY_PORT_STATE} (${EMBY_PORT})
- HTTP：${EMBY_HTTP_CODE}
- 响应耗时：${EMBY_HTTP_TIME}s
- 响应大小：${EMBY_HTTP_SIZE} bytes
- curl返回码：${EMBY_CURL_RC}
- 内容校验：${EMBY_BODY_VALID}
- 结论：${EMBY_REASON}
EOF_EMBY
}

pro189_summary() {
    cat <<EOF_PRO
二、189Pro
- 状态：$( (( PRO189_OK == 1 )) && echo 正常 || echo 异常 )
- 容器名：${PRO189_CONTAINER_NAME}
- 容器存在：${PRO189_CONTAINER_EXISTS}
- 容器运行：${PRO189_CONTAINER_RUNNING}
- Health：${PRO189_CONTAINER_HEALTH}
- 端口：${PRO189_PORT_STATE} (${PRO189_PORT})
- HTTP：${PRO189_HTTP_CODE}
- 响应耗时：${PRO189_HTTP_TIME}s
- 响应大小：${PRO189_HTTP_SIZE} bytes
- curl返回码：${PRO189_CURL_RC}
- 内容校验：${PRO189_BODY_VALID}
- 结论：${PRO189_REASON}
EOF_PRO
}

breaker_text() {
    local active="$1"
    local until_epoch="$2"

    if (( active == 1 )); then
        local remain=$(( until_epoch - $(now_epoch) ))
        (( remain < 0 )) && remain=0
        printf '已触发（剩余 %s）' "$(human_duration "$remain")"
    else
        printf '未触发'
    fi
}

guard_summary() {
    local runtime
    runtime=$(( $(now_epoch) - START_EPOCH ))

    cat <<EOF_GUARD
三、守护与恢复
- 运行时长：$(human_duration "$runtime")
- 守护暂停：$( [ -f "$GUARD_PAUSE_FILE" ] && echo 是 || echo 否 )
- Emby连续失败：${EMBY_FAIL_COUNT}/${EMBY_MAX_FAILURES}
- 189Pro连续失败：${PRO189_FAIL_COUNT}/${PRO189_MAX_FAILURES}
- Emby累计自动恢复：${EMBY_TOTAL_RESTARTS}
- 189Pro累计自动恢复：${PRO189_TOTAL_RESTARTS}
- Emby熔断：$(breaker_text "$EMBY_BREAKER_ACTIVE" "$EMBY_BREAKER_UNTIL_EPOCH")
- 189Pro熔断：$(breaker_text "$PRO189_BREAKER_ACTIVE" "$PRO189_BREAKER_UNTIL_EPOCH")
EOF_GUARD
}

full_status_summary() {
    cat <<EOF_ALL
$(guard_summary)

$(emby_summary)

$(pro189_summary)

总结：以上为当前完整状态快照。
EOF_ALL
}

short_overview_line() {
    printf 'Emby=%s(http:%s svc:%s) | 189Pro=%s(http:%s run:%s)' \
        "$(( EMBY_OK == 1 ? 1 : 0 ))" "$EMBY_HTTP_CODE" "$EMBY_SERVICE_STATE" \
        "$(( PRO189_OK == 1 ? 1 : 0 ))" "$PRO189_HTTP_CODE" "$PRO189_CONTAINER_RUNNING"
}

# =========================================================
# 历史 / 熔断
# =========================================================
prune_history() {
    local file="$1"
    local cutoff=$(( $(now_epoch) - BREAKER_WINDOW_SECONDS ))
    local tmp="${file}.tmp"

    touch "$file"
    awk -v cutoff="$cutoff" '($1+0) >= cutoff {print $1}' "$file" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

count_recent_history() {
    local file="$1"
    prune_history "$file"
    wc -l < "$file" 2>/dev/null | tr -d '[:space:]'
}

record_history() {
    local file="$1"
    printf '%s\n' "$(now_epoch)" >> "$file"
    prune_history "$file"
}

breaker_auto_release_check() {
    local which="$1"
    local now active_var start_var until_var save_func

    now="$(now_epoch)"

    if [ "$which" = "emby" ]; then
        active_var="EMBY_BREAKER_ACTIVE"
        start_var="EMBY_BREAKER_START_EPOCH"
        until_var="EMBY_BREAKER_UNTIL_EPOCH"
        save_func="save_emby_breaker"
    else
        active_var="PRO189_BREAKER_ACTIVE"
        start_var="PRO189_BREAKER_START_EPOCH"
        until_var="PRO189_BREAKER_UNTIL_EPOCH"
        save_func="save_pro189_breaker"
    fi

    if (( ${!active_var} == 1 )) && (( now >= ${!until_var} )); then
        if is_true "$BREAKER_AUTO_RELEASE"; then
            printf -v "$active_var" '%s' 0
            printf -v "$start_var" '%s' 0
            printf -v "$until_var" '%s' 0
            "$save_func"
            log_main "WARN" "${which} 熔断已自动解除。"
            send_tg_message "【熔断解除】${which} 已恢复自动抢救能力" "$(full_status_summary)" || true
        fi
    fi
}

activate_breaker() {
    local which="$1"

    if [ "$which" = "emby" ]; then
        EMBY_BREAKER_ACTIVE=1
        EMBY_BREAKER_START_EPOCH="$(now_epoch)"
        EMBY_BREAKER_UNTIL_EPOCH=$(( EMBY_BREAKER_START_EPOCH + BREAKER_HOLD_SECONDS ))
        save_emby_breaker
        log_main "ERROR" "Emby 熔断触发：${BREAKER_WINDOW_SECONDS}s 内恢复次数达到上限 ${EMBY_BREAKER_MAX_RESTARTS}，暂停自动恢复 ${BREAKER_HOLD_SECONDS}s。"
        if is_true "$TG_NOTIFY_BREAKER"; then
            send_tg_message "【熔断告警】Emby 自动恢复已暂停" "$(full_status_summary)" || true
        fi
    else
        PRO189_BREAKER_ACTIVE=1
        PRO189_BREAKER_START_EPOCH="$(now_epoch)"
        PRO189_BREAKER_UNTIL_EPOCH=$(( PRO189_BREAKER_START_EPOCH + BREAKER_HOLD_SECONDS ))
        save_pro189_breaker
        log_main "ERROR" "189Pro 熔断触发：${BREAKER_WINDOW_SECONDS}s 内恢复次数达到上限 ${PRO189_BREAKER_MAX_RESTARTS}，暂停自动恢复 ${BREAKER_HOLD_SECONDS}s。"
        if is_true "$TG_NOTIFY_BREAKER"; then
            send_tg_message "【熔断告警】189Pro 自动恢复已暂停" "$(full_status_summary)" || true
        fi
    fi
}

# =========================================================
# 等待恢复验证
# =========================================================
wait_for_emby_recovery() {
    local max_wait="$1"
    local waited=0

    while (( waited < max_wait )); do
        check_emby_health || true
        if (( EMBY_OK == 1 )); then
            return 0
        fi
        log_debug "DEBUG" "等待 Emby 恢复中 | 已等待=${waited}s | 原因=${EMBY_REASON}"
        sleep "$RECOVERY_POLL_INTERVAL"
        waited=$(( waited + RECOVERY_POLL_INTERVAL ))
    done

    check_emby_health || true
    return 1
}

wait_for_pro189_recovery() {
    local max_wait="$1"
    local waited=0

    while (( waited < max_wait )); do
        check_pro189_health || true
        if (( PRO189_OK == 1 )); then
            return 0
        fi
        log_debug "DEBUG" "等待 189Pro 恢复中 | 已等待=${waited}s | 原因=${PRO189_REASON}"
        sleep "$RECOVERY_POLL_INTERVAL"
        waited=$(( waited + RECOVERY_POLL_INTERVAL ))
    done

    check_pro189_health || true
    return 1
}

# =========================================================
# 具体动作
# =========================================================
restart_emby() {
    local mode="${1:-auto}"
    local actor="${2:-guard}"
    local begin recent rc

    breaker_auto_release_check emby || true

    if [ "$mode" = "auto" ]; then
        if (( EMBY_BREAKER_ACTIVE == 1 )); then
            log_main "WARN" "Emby 当前处于熔断期，跳过自动恢复。"
            return 2
        fi

        recent="$(count_recent_history "$EMBY_HISTORY_FILE")"
        if (( recent >= EMBY_BREAKER_MAX_RESTARTS )); then
            activate_breaker emby
            return 2
        fi
    fi

    acquire_action_lock "restart_emby:${mode}:${actor}" || return 3
    begin="$(now_epoch)"

    log_action "INFO" "开始重启 Emby | mode=${mode} | actor=${actor}"
    if is_true "$TG_NOTIFY_RECOVERY_START"; then
        send_tg_message "【开始恢复】Emby 正在重启" "触发来源：${actor}
执行模式：${mode}

$(emby_summary)" || true
    fi

    if [ "$mode" = "auto" ]; then
        record_history "$EMBY_HISTORY_FILE"
        EMBY_TOTAL_RESTARTS=$(( EMBY_TOTAL_RESTARTS + 1 ))
        save_guard_state
    fi

    if run_quiet systemctl restart "$SERVICE_NAME"; then
        rc=0
    else
        rc=$?
    fi
    log_action "INFO" "systemctl restart ${SERVICE_NAME} 返回=${rc}"

    if wait_for_emby_recovery "$EMBY_RECOVERY_WAIT_AFTER_RESTART"; then
        log_main "INFO" "Emby 恢复成功（优雅重启），耗时 $(human_duration $(( $(now_epoch) - begin )))。"
        if is_true "$TG_NOTIFY_RECOVERY_SUCCESS"; then
            send_tg_message "【恢复成功】Emby 已恢复" "方式：systemctl restart
耗时：$(human_duration $(( $(now_epoch) - begin )))

$(emby_summary)" || true
        fi
        release_action_lock
        sleep "$COOLDOWN_AFTER_RECOVERY"
        return 0
    fi

    log_action "ERROR" "优雅重启后 Emby 仍未恢复：${EMBY_REASON}"

    run_quiet systemctl kill -s SIGKILL "$SERVICE_NAME" || true
    sleep "$FORCE_KILL_WAIT"
    run_quiet systemctl reset-failed "$SERVICE_NAME" || true

    if run_quiet systemctl start "$SERVICE_NAME"; then
        rc=0
    else
        rc=$?
    fi
    log_action "INFO" "systemctl start ${SERVICE_NAME} 返回=${rc}"

    if wait_for_emby_recovery "$EMBY_RECOVERY_WAIT_AFTER_FORCE_START"; then
        log_main "INFO" "Emby 恢复成功（强制重启），耗时 $(human_duration $(( $(now_epoch) - begin )))。"
        if is_true "$TG_NOTIFY_RECOVERY_SUCCESS"; then
            send_tg_message "【恢复成功】Emby 已恢复" "方式：SIGKILL + start
耗时：$(human_duration $(( $(now_epoch) - begin )))

$(emby_summary)" || true
        fi
        release_action_lock
        sleep "$COOLDOWN_AFTER_RECOVERY"
        return 0
    fi

    log_main "ERROR" "Emby 自动恢复失败，耗时 $(human_duration $(( $(now_epoch) - begin )))。当前：${EMBY_REASON}"
    if is_true "$TG_NOTIFY_RECOVERY_FAILURE"; then
        send_tg_message "【恢复失败】Emby 自动恢复失败" "耗时：$(human_duration $(( $(now_epoch) - begin )))
触发来源：${actor}

$(emby_summary)" || true
    fi

    release_action_lock

    if [ "$mode" = "auto" ] && (( $(count_recent_history "$EMBY_HISTORY_FILE") >= EMBY_BREAKER_MAX_RESTARTS )); then
        activate_breaker emby
    fi

    return 1
}

restart_pro189() {
    local mode="${1:-auto}"
    local actor="${2:-guard}"
    local begin recent rc

    breaker_auto_release_check pro189 || true

    if [ "$mode" = "auto" ]; then
        if (( PRO189_BREAKER_ACTIVE == 1 )); then
            log_main "WARN" "189Pro 当前处于熔断期，跳过自动恢复。"
            return 2
        fi

        recent="$(count_recent_history "$PRO189_HISTORY_FILE")"
        if (( recent >= PRO189_BREAKER_MAX_RESTARTS )); then
            activate_breaker pro189
            return 2
        fi
    fi

    acquire_action_lock "restart_pro189:${mode}:${actor}" || return 3
    begin="$(now_epoch)"

    log_action "INFO" "开始重启 189Pro 容器 | mode=${mode} | actor=${actor} | container=${PRO189_CONTAINER_NAME}"
    if is_true "$TG_NOTIFY_RECOVERY_START"; then
        send_tg_message "【开始恢复】189Pro 正在重启" "触发来源：${actor}
执行模式：${mode}

$(pro189_summary)" || true
    fi

    if [ "$mode" = "auto" ]; then
        record_history "$PRO189_HISTORY_FILE"
        PRO189_TOTAL_RESTARTS=$(( PRO189_TOTAL_RESTARTS + 1 ))
        save_guard_state
    fi

    if run_quiet docker restart "$PRO189_CONTAINER_NAME"; then
        rc=0
    else
        rc=$?
    fi
    log_action "INFO" "docker restart ${PRO189_CONTAINER_NAME} 返回=${rc}"

    if wait_for_pro189_recovery "$PRO189_RECOVERY_WAIT_AFTER_RESTART"; then
        log_main "INFO" "189Pro 恢复成功（docker restart），耗时 $(human_duration $(( $(now_epoch) - begin )))。"
        if is_true "$TG_NOTIFY_RECOVERY_SUCCESS"; then
            send_tg_message "【恢复成功】189Pro 已恢复" "方式：docker restart
耗时：$(human_duration $(( $(now_epoch) - begin )))

$(pro189_summary)" || true
        fi
        release_action_lock
        sleep "$COOLDOWN_AFTER_RECOVERY"
        return 0
    fi

    log_action "ERROR" "docker restart 后 189Pro 仍未恢复：${PRO189_REASON}"

    run_quiet docker stop -t 3 "$PRO189_CONTAINER_NAME" || true
    if run_quiet docker start "$PRO189_CONTAINER_NAME"; then
        rc=0
    else
        rc=$?
    fi
    log_action "INFO" "docker start ${PRO189_CONTAINER_NAME} 返回=${rc}"

    if wait_for_pro189_recovery "$PRO189_RECOVERY_WAIT_AFTER_FORCE_START"; then
        log_main "INFO" "189Pro 恢复成功（stop/start），耗时 $(human_duration $(( $(now_epoch) - begin )))。"
        if is_true "$TG_NOTIFY_RECOVERY_SUCCESS"; then
            send_tg_message "【恢复成功】189Pro 已恢复" "方式：docker stop/start
耗时：$(human_duration $(( $(now_epoch) - begin )))

$(pro189_summary)" || true
        fi
        release_action_lock
        sleep "$COOLDOWN_AFTER_RECOVERY"
        return 0
    fi

    log_main "ERROR" "189Pro 自动恢复失败，耗时 $(human_duration $(( $(now_epoch) - begin )))。当前：${PRO189_REASON}"
    if is_true "$TG_NOTIFY_RECOVERY_FAILURE"; then
        send_tg_message "【恢复失败】189Pro 自动恢复失败" "耗时：$(human_duration $(( $(now_epoch) - begin )))
触发来源：${actor}

$(pro189_summary)" || true
    fi

    release_action_lock

    if [ "$mode" = "auto" ] && (( $(count_recent_history "$PRO189_HISTORY_FILE") >= PRO189_BREAKER_MAX_RESTARTS )); then
        activate_breaker pro189
    fi

    return 1
}

restart_all_services() {
    local actor="${1:-manual}"
    local r1=0 r2=0

    restart_emby manual "$actor" || r1=$?
    check_all_health || true
    restart_pro189 manual "$actor" || r2=$?
    check_all_health || true

    if (( r1 == 0 && r2 == 0 )); then
        return 0
    fi
    return 1
}

# =========================================================
# 守护辅助
# =========================================================
notify_key_from_title() {
    local title="$1"
    case "$title" in
        *Emby*) echo "emby" ;;
        *189Pro*|*189pro*|*189PRO*) echo "pro189" ;;
        *) echo "global" ;;
    esac
}

warning_notify_if_needed() {
    local title="$1"
    local body="$2"
    local now key last_var

    now="$(now_epoch)"
    if ! is_true "$TG_NOTIFY_WARNING"; then return 0; fi

    key="$(notify_key_from_title "$title")"
    case "$key" in
        emby)   last_var="LAST_EMBY_WARNING_NOTIFY_EPOCH" ;;
        pro189) last_var="LAST_PRO189_WARNING_NOTIFY_EPOCH" ;;
        *)      last_var="LAST_WARNING_NOTIFY_EPOCH" ;;
    esac

    if (( now - ${!last_var:-0} < TG_WARNING_MIN_GAP )); then return 0; fi

    printf -v "$last_var" '%s' "$now"
    LAST_WARNING_NOTIFY_EPOCH="$now"
    save_guard_state
    send_tg_message "$title" "$body" || true
}

failure_notify_if_needed() {
    local title="$1"
    local body="$2"
    local now key last_var

    now="$(now_epoch)"
    key="$(notify_key_from_title "$title")"
    case "$key" in
        emby)   last_var="LAST_EMBY_FAILURE_NOTIFY_EPOCH" ;;
        pro189) last_var="LAST_PRO189_FAILURE_NOTIFY_EPOCH" ;;
        *)      last_var="LAST_FAILURE_NOTIFY_EPOCH" ;;
    esac

    if (( now - ${!last_var:-0} < TG_FAILURE_MIN_GAP )); then return 0; fi

    printf -v "$last_var" '%s' "$now"
    LAST_FAILURE_NOTIFY_EPOCH="$now"
    save_guard_state
    send_tg_message "$title" "$body" || true
}

startup_notify() {
    local component="$1"
    log_main "INFO" "${component} 启动完成。$(short_overview_line)"
    if is_true "$TG_NOTIFY_SCRIPT_START"; then
        send_tg_message "【脚本启动】${component} 已启动" "$(full_status_summary)" || true
    fi
}

shutdown_notify() {
    local component="$1"
    log_main "WARN" "${component} 已停止。"
    if is_true "$TG_NOTIFY_SCRIPT_STOP"; then
        send_tg_message "【脚本停止】${component} 已退出" "$(full_status_summary)" || true
    fi
}

periodic_heartbeat_if_needed() {
    local now
    now="$(now_epoch)"

    if (( now - LAST_HEARTBEAT_LOG_EPOCH >= HEARTBEAT_LOG_INTERVAL )); then
        log_main "INFO" "健康心跳：$(short_overview_line)"
        LAST_HEARTBEAT_LOG_EPOCH="$now"
        save_guard_state
    fi

    if is_true "$TG_NOTIFY_STATUS_HEARTBEAT" && (( now - LAST_HEARTBEAT_TG_EPOCH >= TG_STATUS_HEARTBEAT_INTERVAL )); then
        send_tg_message "【状态心跳】当前服务运行正常" "$(full_status_summary)" || true
        LAST_HEARTBEAT_TG_EPOCH="$now"
        save_guard_state
    fi

    if is_true "$DEBUG_LOG_ENABLE" && (( DEBUG_HEALTH_LOG_INTERVAL > 0 )) && (( now - LAST_DEBUG_HEALTH_LOG_EPOCH >= DEBUG_HEALTH_LOG_INTERVAL )); then
        log_debug "DEBUG" "周期性健康日志 | $(short_overview_line)"
        LAST_DEBUG_HEALTH_LOG_EPOCH="$now"
        save_guard_state
    fi
}

guard_is_paused() {
    [ -f "$GUARD_PAUSE_FILE" ]
}

pause_guard() {
    printf 'paused_by=%s\ntime=%s\n' "${1:-unknown}" "$(now_beijing)" > "$GUARD_PAUSE_FILE"
}

resume_guard() {
    rm -f "$GUARD_PAUSE_FILE"
}

# =========================================================
# TG 控制辅助
# =========================================================
list_contains_csv() {
    local list="$1"
    local value="$2"
    local item

    [ -n "$list" ] || return 1
    IFS=',' read -ra __items <<< "$list"

    for item in "${__items[@]}"; do
        item="${item//[[:space:]]/}"
        [ -n "$item" ] || continue
        [ "$item" = "$value" ] && return 0
    done
    return 1
}

authorized_chat() {
    local chat_id="$1"
    list_contains_csv "$TG_ALLOW_CHAT_IDS" "$chat_id"
}

authorized_user() {
    local user_id="$1"
    if [ -z "$TG_ALLOW_USER_IDS" ]; then
        return 0
    fi
    list_contains_csv "$TG_ALLOW_USER_IDS" "$user_id"
}

load_tg_offset() {
    if [ -f "$TG_STATE_FILE" ]; then
        awk -F'=' '/^OFFSET=/{print $2}' "$TG_STATE_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

save_tg_offset() {
    local offset="$1"
    printf 'OFFSET=%s\n' "$offset" > "$TG_STATE_FILE"
}

telegram_get_updates() {
    local offset="$1"
    local api_url tmp_err resp rc

    api_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates"
    tmp_err="$(mktemp -p "$TMP_DIR" tg_updates_err.XXXXXX)"

    local -a curl_args=(
        -sS
        --connect-timeout 8
        --max-time $(( TG_POLL_TIMEOUT + 10 ))
        -X POST
        "$api_url"
        --data-urlencode "offset=${offset}"
        --data-urlencode "timeout=${TG_POLL_TIMEOUT}"
        --data "allowed_updates=[\"message\"]"
    )
    [ -n "$TG_PROXY" ] && curl_args+=(--proxy "$TG_PROXY")

    set +e
    resp="$(curl "${curl_args[@]}" 2>"$tmp_err")"
    rc=$?
    set -e

    if (( rc != 0 )); then
        log_tg "ERROR" "getUpdates 失败：curl_rc=${rc} | err=$(truncate_text "$(cat "$tmp_err" 2>/dev/null || true)" 220)"
        rm -f "$tmp_err"
        return 1
    fi

    rm -f "$tmp_err"
    printf '%s' "$resp"
    return 0
}

parse_updates_to_lines() {
    python3 -c '
import sys, json, base64

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

for item in data.get("result", []):
    upd = item.get("update_id", "")
    msg = item.get("message", {})
    chat = msg.get("chat", {})
    from_user = msg.get("from", {})

    text = msg.get("text", "") or ""
    first = from_user.get("first_name", "") or ""
    username = from_user.get("username", "") or ""
    name = (first + (f" (@{username})" if username else "")).strip()

    fields = [
        str(upd),
        str(chat.get("id", "")),
        str(from_user.get("id", "")),
        base64.b64encode(text.encode()).decode(),
        str(chat.get("type", "")),
        base64.b64encode(name.encode()).decode(),
    ]
    print("\t".join(fields))
'
}

decode_b64() {
    python3 - <<'PY' "$1"
import sys, base64
try:
    print(base64.b64decode(sys.argv[1]).decode())
except Exception:
    print("")
PY
}

# =========================================================
# 初始化
# =========================================================
init_suite() {
    ensure_dirs
    require_commands
    load_guard_state
    load_breakers
}
