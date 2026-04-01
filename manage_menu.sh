#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="/cloud189pro/emby检测"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"

GUARD_SCRIPT="${BASE_DIR}/emby_guard.sh"
TG_SCRIPT="${BASE_DIR}/tg_control.sh"
OLD_SCRIPT="${BASE_DIR}/embyjc.sh"

GUARD_PID_FILE="${RUN_DIR}/emby_guard.pid"
TG_PID_FILE="${RUN_DIR}/tg_control.pid"

MANAGER_LOG="${LOG_DIR}/manage_menu.log"
GUARD_NOHUP_LOG="${LOG_DIR}/emby_guard.nohup.log"
TG_NOHUP_LOG="${LOG_DIR}/tg_control.nohup.log"

EMBY_SERVICE="emby-server"
OLD_SERVICE="emby-monitor.service"
PRO189_CONTAINER="cloud189pro"

WAIT_SERVICE_SECONDS=20
WAIT_CONTAINER_SECONDS=20
WAIT_SCRIPT_SECONDS=10

ts() { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
log() { mkdir -p "$LOG_DIR"; echo "[$(ts)] $*" | tee -a "$MANAGER_LOG" >/dev/null; }
ok() { echo -e "\033[32m$*\033[0m"; }
warn() { echo -e "\033[33m$*\033[0m"; }
err() { echo -e "\033[31m$*\033[0m"; }
info() { echo -e "\033[36m$*\033[0m"; }
pause_wait() { echo; read -rp "按回车继续..."; }
ensure_dirs() { mkdir -p "$BASE_DIR" "$LOG_DIR" "$RUN_DIR"; touch "$MANAGER_LOG" "$GUARD_NOHUP_LOG" "$TG_NOHUP_LOG"; }

require_cmds() {
    local cmds=(bash nohup pkill pgrep systemctl docker grep awk sed sleep head tail paste chmod mkdir touch)
    local missing=()
    for c in "${cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if ((${#missing[@]} > 0)); then err "缺少命令：${missing[*]}"; exit 1; fi
}

read_pid_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local pid; pid="$(cat "$file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    echo "$pid"
}
write_pid_file() { echo "$2" > "$1"; }
remove_pid_file() { rm -f "$1"; }

script_running() { pgrep -f -- "$1" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$1"; }
service_state_text() { systemctl is-active "$1" 2>/dev/null || echo "unknown"; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]; }
container_status_text() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "unknown"; }

wait_for_service_active() {
    local service="$1" timeout="${2:-20}" i=0
    while (( i < timeout )); do service_active "$service" && return 0; sleep 1; i=$((i+1)); done
    return 1
}
wait_for_container_running() {
    local container="$1" timeout="${2:-20}" i=0
    while (( i < timeout )); do
        if container_exists "$container" && container_running "$container"; then return 0; fi
        sleep 1; i=$((i+1))
    done
    return 1
}
wait_for_script_started() {
    local script="$1" timeout="${2:-10}" i=0
    while (( i < timeout )); do script_running "$script" && return 0; sleep 1; i=$((i+1)); done
    return 1
}
wait_for_script_stopped() {
    local script="$1" timeout="${2:-10}" i=0
    while (( i < timeout )); do ! script_running "$script" && return 0; sleep 1; i=$((i+1)); done
    return 1
}

stop_old_monitor() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_SERVICE}"; then
        systemctl stop "$OLD_SERVICE" 2>/dev/null || true
        systemctl disable "$OLD_SERVICE" 2>/dev/null || true
        systemctl mask "$OLD_SERVICE" 2>/dev/null || true
        log "[旧监控] 已停止并屏蔽 ${OLD_SERVICE}"
    fi
    if script_running "$OLD_SCRIPT"; then pkill -9 -f -- "$OLD_SCRIPT" >/dev/null 2>&1 || true; log "[旧监控] 已强制停止旧脚本 ${OLD_SCRIPT}"; fi
}

start_bg_script() {
    local name="$1" script="$2" pid_file="$3" out_log="$4"
    if [[ ! -f "$script" ]]; then err "[${name}] 脚本不存在：$script"; log "[${name}] 启动失败，脚本不存在"; return 1; fi
    chmod +x "$script"
    if script_running "$script"; then
        local exist_pid; exist_pid="$(pgrep -f -- "$script" | head -n1)"
        write_pid_file "$pid_file" "$exist_pid"
        info "[${name}] 已在运行，PID=${exist_pid}"
        return 0
    fi
    nohup /bin/bash "$script" >> "$out_log" 2>&1 &
    local new_pid=$!
    if wait_for_script_started "$script" "$WAIT_SCRIPT_SECONDS"; then
        local real_pid; real_pid="$(pgrep -f -- "$script" | head -n1)"
        write_pid_file "$pid_file" "${real_pid:-$new_pid}"
        ok "[${name}] 启动成功"
        log "[${name}] 启动成功，PID=${real_pid:-$new_pid}"
        return 0
    fi
    err "[${name}] 启动失败"
    log "[${name}] 启动失败，请检查日志：$out_log"
    return 1
}

stop_bg_script() {
    local name="$1" script="$2" pid_file="$3" did_stop=0 pid=""
    if pid="$(read_pid_file "$pid_file" 2>/dev/null || true)"; then
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill "$pid" >/dev/null 2>&1 || true
            if ! wait_for_script_stopped "$script" 3; then kill -9 "$pid" >/dev/null 2>&1 || true; fi
            did_stop=1; log "[${name}] 已按 PID 停止，PID=${pid}"
        fi
        remove_pid_file "$pid_file"
    fi
    if script_running "$script"; then
        pkill -f -- "$script" >/dev/null 2>&1 || true
        if ! wait_for_script_stopped "$script" 3; then pkill -9 -f -- "$script" >/dev/null 2>&1 || true; fi
        did_stop=1; log "[${name}] 已按脚本路径停止"
    fi
    if (( did_stop == 1 )); then ok "[${name}] 已停止"; else info "[${name}] 本来就没在运行"; fi
}

TOOLS_WERE_RUNNING_GUARD=0
TOOLS_WERE_RUNNING_TG=0
remember_tools_state() {
    TOOLS_WERE_RUNNING_GUARD=0; TOOLS_WERE_RUNNING_TG=0
    script_running "$GUARD_SCRIPT" && TOOLS_WERE_RUNNING_GUARD=1
    script_running "$TG_SCRIPT" && TOOLS_WERE_RUNNING_TG=1
}
start_tools() {
    stop_old_monitor
    local guard_ok=1 tg_ok=1
    start_bg_script "emby_guard" "$GUARD_SCRIPT" "$GUARD_PID_FILE" "$GUARD_NOHUP_LOG" || guard_ok=0
    start_bg_script "tg_control" "$TG_SCRIPT" "$TG_PID_FILE" "$TG_NOHUP_LOG" || tg_ok=0
    (( guard_ok == 1 && tg_ok == 1 ))
}
stop_tools() {
    stop_bg_script "tg_control" "$TG_SCRIPT" "$TG_PID_FILE"
    stop_bg_script "emby_guard" "$GUARD_SCRIPT" "$GUARD_PID_FILE"
    stop_old_monitor
}
restore_tools_if_needed() {
    local restore_ok=1
    (( TOOLS_WERE_RUNNING_GUARD == 1 )) && start_bg_script "emby_guard" "$GUARD_SCRIPT" "$GUARD_PID_FILE" "$GUARD_NOHUP_LOG" || true
    if (( TOOLS_WERE_RUNNING_GUARD == 1 )) && ! script_running "$GUARD_SCRIPT"; then restore_ok=0; fi
    (( TOOLS_WERE_RUNNING_TG == 1 )) && start_bg_script "tg_control" "$TG_SCRIPT" "$TG_PID_FILE" "$TG_NOHUP_LOG" || true
    if (( TOOLS_WERE_RUNNING_TG == 1 )) && ! script_running "$TG_SCRIPT"; then restore_ok=0; fi
    return $(( restore_ok == 1 ? 0 : 1 ))
}

restart_emby() {
    info "正在重启 Emby..."
    systemctl restart "$EMBY_SERVICE" || true
    if wait_for_service_active "$EMBY_SERVICE" "$WAIT_SERVICE_SECONDS"; then ok "Emby 重启成功"; log "[Emby] 重启成功"; return 0; fi
    err "Emby 重启后状态异常"; log "[Emby] 重启后状态异常 | state=$(service_state_text "$EMBY_SERVICE")"; return 1
}
restart_189pro() {
    info "正在重启 189Pro..."
    docker restart "$PRO189_CONTAINER" >/dev/null 2>&1 || true
    if wait_for_container_running "$PRO189_CONTAINER" "$WAIT_CONTAINER_SECONDS"; then ok "189Pro 重启成功"; log "[189Pro] 重启成功"; return 0; fi
    err "189Pro 重启后状态异常"; log "[189Pro] 重启后状态异常 | status=$(container_status_text "$PRO189_CONTAINER")"; return 1
}

restart_tools_only() {
    echo; info "========== 重启命令工具 =========="
    stop_tools
    if start_tools; then ok "命令工具重启完成"; log "[命令工具重启] 执行完成"; else err "命令工具重启有失败"; log "[命令工具重启] 有失败"; fi
    echo
}
stop_tools_only() {
    echo; info "========== 关闭检测工具 =========="
    stop_tools
    ok "检测工具已关闭，Emby 和 189Pro 未关闭"
    log "[关闭检测工具] 执行完成"
    echo
}
restart_emby_and_189pro() {
    echo; info "========== 重启 Emby + 189Pro =========="
    remember_tools_state; stop_tools
    local emby_ok=1 pro_ok=1 restore_ok=1
    restart_emby || emby_ok=0
    restart_189pro || pro_ok=0
    restore_tools_if_needed || restore_ok=0
    echo
    if (( emby_ok == 1 && pro_ok == 1 && restore_ok == 1 )); then ok "Emby + 189Pro 重启完成"; log "[重启 Emby+189Pro] 执行完成"; else err "Emby + 189Pro 重启未全部成功"; log "[重启 Emby+189Pro] 有失败"; fi
}
restart_189pro_only_safe() {
    echo; info "========== 重启 189Pro =========="
    remember_tools_state; stop_tools
    local pro_ok=1 restore_ok=1
    restart_189pro || pro_ok=0
    restore_tools_if_needed || restore_ok=0
    echo
    if (( pro_ok == 1 && restore_ok == 1 )); then ok "189Pro 重启完成"; log "[重启 189Pro] 执行完成"; else err "189Pro 重启未全部成功"; log "[重启 189Pro] 有失败"; fi
}
restart_all_full() {
    echo; info "========== 重启全部（命令工具 + Emby + 189Pro） =========="
    stop_tools
    local emby_ok=1 pro_ok=1 tools_ok=1
    restart_emby || emby_ok=0
    restart_189pro || pro_ok=0
    start_tools || tools_ok=0
    echo
    if (( emby_ok == 1 && pro_ok == 1 && tools_ok == 1 )); then ok "全部重启完成"; log "[重启全部] 执行完成"; else err "全部重启未全部成功"; log "[重启全部] 有失败"; fi
}

show_status() {
    echo; info "================ 当前状态 ================"
    echo "[Emby]        $(service_state_text "$EMBY_SERVICE")"
    if container_exists "$PRO189_CONTAINER"; then echo "[189Pro]      $(container_status_text "$PRO189_CONTAINER")"; else echo "[189Pro]      容器不存在"; fi
    if script_running "$GUARD_SCRIPT"; then echo "[emby_guard]  运行中 | PID: $(pgrep -f -- "$GUARD_SCRIPT" | paste -sd ',' -)"; else echo "[emby_guard]  未运行"; fi
    if script_running "$TG_SCRIPT"; then echo "[tg_control]  运行中 | PID: $(pgrep -f -- "$TG_SCRIPT" | paste -sd ',' -)"; else echo "[tg_control]  未运行"; fi
    if script_running "$OLD_SCRIPT"; then echo "[旧 embyjc]   仍在运行 | PID: $(pgrep -f -- "$OLD_SCRIPT" | paste -sd ',' -)"; else echo "[旧 embyjc]   未运行"; fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_SERVICE}"; then
        local old_state; old_state="$(systemctl is-active "$OLD_SERVICE" 2>/dev/null || true)"
        echo "[旧服务]      ${OLD_SERVICE} | ${old_state:-unknown}"
    fi
    echo
    echo "管理日志：$MANAGER_LOG"
    echo "守护日志：${LOG_DIR}/guard.log"
    echo "控制日志：${LOG_DIR}/tg_control.log"
    echo "TG日志：  ${LOG_DIR}/telegram.log"
    echo "动作日志：${LOG_DIR}/actions.log"
    echo "守护 nohup：${GUARD_NOHUP_LOG}"
    echo "TG nohup：  ${TG_NOHUP_LOG}"
    echo
}

draw_menu() {
    clear
    echo "=================================================="
    echo "          Emby / 189Pro / 检测工具 管理菜单"
    echo "=================================================="
    echo "  1) 重启命令工具"
    echo "  2) 重启全部（命令工具 + Emby + 189Pro）"
    echo "  3) 重启 Emby + 189Pro"
    echo "  4) 重启 189Pro"
    echo "  5) 关闭检测工具（不关闭 Emby 和 189Pro）"
    echo "  6) 查看状态"
    echo "  0) 退出"
    echo "=================================================="
    echo
}

main() {
    ensure_dirs; require_cmds
    while true; do
        draw_menu
        read -rp "请输入选项: " choice
        echo
        case "${choice:-}" in
            1) restart_tools_only; pause_wait ;;
            2) restart_all_full; pause_wait ;;
            3) restart_emby_and_189pro; pause_wait ;;
            4) restart_189pro_only_safe; pause_wait ;;
            5) stop_tools_only; pause_wait ;;
            6) show_status; pause_wait ;;
            0) echo "已退出。"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; pause_wait ;;
        esac
    done
}
main "$@"
