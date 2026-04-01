#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/actions.sh"

COMPONENT_NAME="主守护进程"

PAUSE_LOGGED=0
LAST_PAUSE_HEARTBEAT_TS=0
PAUSE_HEARTBEAT_INTERVAL=1800

now_epoch() {
    date +%s
}

safe_check_all_health() {
    if ! check_all_health; then
        log_main "ERROR" "check_all_health 执行异常，沿用当前已知状态继续运行。"
        return 1
    fi
    return 0
}

safe_check_emby_health() {
    if ! check_emby_health; then
        log_main "ERROR" "check_emby_health 执行异常，沿用当前已知 Emby 状态继续运行。"
        return 1
    fi
    return 0
}

clear_pause_log_state() {
    PAUSE_LOGGED=0
    LAST_PAUSE_HEARTBEAT_TS=0
}

mark_recovered_if_needed() {
    local service_name="$1"
    local old_fail_count="$2"
    local summary="$3"

    if (( old_fail_count > 0 )); then
        log_main "INFO" "${service_name} 已恢复正常，失败计数清零。${summary}"
    fi
}

record_pause_if_needed() {
    local now
    now="$(now_epoch)"

    if (( PAUSE_LOGGED == 0 )); then
        log_main "WARN" "守护已暂停，跳过自动恢复。$(short_overview_line)"
        PAUSE_LOGGED=1
        LAST_PAUSE_HEARTBEAT_TS="$now"
        return 0
    fi

    if (( now - LAST_PAUSE_HEARTBEAT_TS >= PAUSE_HEARTBEAT_INTERVAL )); then
        log_main "WARN" "守护仍处于暂停状态，自动恢复继续关闭。$(short_overview_line)"
        LAST_PAUSE_HEARTBEAT_TS="$now"
    fi
}

handle_guard_paused() {
    record_pause_if_needed
    sleep "$CHECK_INTERVAL"
}

reset_fail_count_after_recovery() {
    local result_ok="$1"
    local current_fail="$2"
    local max_fail="$3"

    if (( result_ok == 1 )); then
        echo 0
    else
        if (( max_fail > 1 )); then
            echo $(( max_fail - 1 ))
        else
            echo "$current_fail"
        fi
    fi
}

cleanup() {
    shutdown_notify "$COMPONENT_NAME"
    release_action_lock
}
trap cleanup EXIT INT TERM

init_suite
acquire_singleton_lock "$MAIN_LOCK_FILE" "$COMPONENT_NAME"

safe_check_all_health || true
startup_notify "$COMPONENT_NAME"

log_main "INFO" "守护参数：CHECK_INTERVAL=${CHECK_INTERVAL}s | RETRY_INTERVAL=${RETRY_INTERVAL}s | Emby阈值=${EMBY_MAX_FAILURES} | 189Pro阈值=${PRO189_MAX_FAILURES}"
log_main "INFO" "主守护已启动。$(short_overview_line)"

while true; do
    breaker_auto_release_check emby || true
    breaker_auto_release_check pro189 || true

    if guard_is_paused; then
        handle_guard_paused
        continue
    fi

    clear_pause_log_state
    safe_check_all_health || true

    PREV_EMBY_FAIL_COUNT="${EMBY_FAIL_COUNT:-0}"

    if (( EMBY_OK == 1 )); then
        mark_recovered_if_needed "Emby" "$PREV_EMBY_FAIL_COUNT" "$(emby_summary)"
        EMBY_FAIL_COUNT=0
    else
        EMBY_FAIL_COUNT=$(( EMBY_FAIL_COUNT + 1 ))
        log_main "WARN" "Emby 检测失败 (${EMBY_FAIL_COUNT}/${EMBY_MAX_FAILURES})：${EMBY_REASON}"
        if (( EMBY_FAIL_COUNT == 1 )); then
            warning_notify_if_needed "【异常预警】Emby 首次异常" "$(emby_summary)"
        fi
    fi

    PREV_PRO189_FAIL_COUNT="${PRO189_FAIL_COUNT:-0}"

    if (( PRO189_OK == 1 )); then
        mark_recovered_if_needed "189Pro" "$PREV_PRO189_FAIL_COUNT" "$(pro189_summary)"
        PRO189_FAIL_COUNT=0
    else
        PRO189_FAIL_COUNT=$(( PRO189_FAIL_COUNT + 1 ))
        log_main "WARN" "189Pro 检测失败 (${PRO189_FAIL_COUNT}/${PRO189_MAX_FAILURES})：${PRO189_REASON}"
        if (( PRO189_FAIL_COUNT == 1 )); then
            warning_notify_if_needed "【异常预警】189Pro 首次异常" "$(pro189_summary)"
        fi
    fi

    save_guard_state

    if (( EMBY_OK == 1 && PRO189_OK == 1 )); then
        periodic_heartbeat_if_needed || true
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if (( EMBY_FAIL_COUNT >= EMBY_MAX_FAILURES )) && (( PRO189_FAIL_COUNT >= PRO189_MAX_FAILURES )); then
        log_main "ERROR" "检测到 Emby 与 189Pro 同时异常，按策略先恢复 Emby，再检查 189Pro。"
        warning_notify_if_needed "【联动异常】Emby 与 189Pro 同时异常" "先恢复 Emby，再检查 189Pro。

$(full_status_summary)"

        EMBY_RECOVERY_OK=1
        PRO189_RECOVERY_OK=1

        if ! restart_emby auto guard; then
            EMBY_RECOVERY_OK=0
            failure_notify_if_needed "【恢复失败】Emby 联动异常恢复失败" "$(emby_summary)"
        fi

        safe_check_all_health || true

        if (( PRO189_OK == 0 )); then
            PRO189_FAIL_COUNT=$PRO189_MAX_FAILURES
            if ! restart_pro189 auto guard; then
                PRO189_RECOVERY_OK=0
                failure_notify_if_needed "【恢复失败】189Pro 联动异常恢复失败" "$(pro189_summary)"
            fi
            safe_check_all_health || true
        fi

        EMBY_FAIL_COUNT="$(reset_fail_count_after_recovery "$EMBY_RECOVERY_OK" "$EMBY_FAIL_COUNT" "$EMBY_MAX_FAILURES")"
        PRO189_FAIL_COUNT="$(reset_fail_count_after_recovery "$PRO189_RECOVERY_OK" "$PRO189_FAIL_COUNT" "$PRO189_MAX_FAILURES")"

        save_guard_state
        sleep "$RETRY_INTERVAL"
        continue
    fi

    if (( EMBY_FAIL_COUNT >= EMBY_MAX_FAILURES )) && (( PRO189_FAIL_COUNT < PRO189_MAX_FAILURES )); then
        log_main "ERROR" "Emby 达到自动恢复阈值，开始抢救。"

        EMBY_RECOVERY_OK=1
        if ! restart_emby auto guard; then
            EMBY_RECOVERY_OK=0
            failure_notify_if_needed "【恢复失败】Emby 自动恢复失败" "$(emby_summary)"
        fi

        EMBY_FAIL_COUNT="$(reset_fail_count_after_recovery "$EMBY_RECOVERY_OK" "$EMBY_FAIL_COUNT" "$EMBY_MAX_FAILURES")"
        save_guard_state
        sleep "$RETRY_INTERVAL"
        continue
    fi

    if (( PRO189_FAIL_COUNT >= PRO189_MAX_FAILURES )) && (( EMBY_FAIL_COUNT < EMBY_MAX_FAILURES )); then
        safe_check_emby_health || true

        if (( EMBY_OK == 1 )); then
            log_main "ERROR" "189Pro 达到自动恢复阈值，Emby 复核正常，开始重启 189Pro。"

            PRO189_RECOVERY_OK=1
            if ! restart_pro189 auto guard; then
                PRO189_RECOVERY_OK=0
                failure_notify_if_needed "【恢复失败】189Pro 自动恢复失败" "$(pro189_summary)"
            fi

            PRO189_FAIL_COUNT="$(reset_fail_count_after_recovery "$PRO189_RECOVERY_OK" "$PRO189_FAIL_COUNT" "$PRO189_MAX_FAILURES")"
            EMBY_FAIL_COUNT=0
        else
            log_main "ERROR" "189Pro 异常时复核发现 Emby 也异常，转为先恢复 Emby。"

            EMBY_FAIL_COUNT=$EMBY_MAX_FAILURES
            EMBY_RECOVERY_OK=1
            PRO189_RECOVERY_OK=1

            if ! restart_emby auto guard; then
                EMBY_RECOVERY_OK=0
                failure_notify_if_needed "【恢复失败】Emby 自动恢复失败" "$(emby_summary)"
            fi

            safe_check_all_health || true

            if (( PRO189_OK == 0 )); then
                if ! restart_pro189 auto guard; then
                    PRO189_RECOVERY_OK=0
                    failure_notify_if_needed "【恢复失败】189Pro 自动恢复失败" "$(pro189_summary)"
                fi
            fi

            EMBY_FAIL_COUNT="$(reset_fail_count_after_recovery "$EMBY_RECOVERY_OK" "$EMBY_FAIL_COUNT" "$EMBY_MAX_FAILURES")"
            PRO189_FAIL_COUNT="$(reset_fail_count_after_recovery "$PRO189_RECOVERY_OK" "$PRO189_FAIL_COUNT" "$PRO189_MAX_FAILURES")"
        fi

        save_guard_state
        sleep "$RETRY_INTERVAL"
        continue
    fi

    sleep "$RETRY_INTERVAL"
done
