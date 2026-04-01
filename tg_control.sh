#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/actions.sh"

COMPONENT_NAME="TG 控制器"

cleanup() {
    log_ctrl "INFO" "TG 控制器正在退出。"
    release_action_lock
}
trap cleanup EXIT INT TERM

now_epoch() {
    date +%s
}

now_beijing() {
    TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'
}

format_elapsed() {
    local start_ts="${1:-0}"
    local end_ts="${2:-0}"
    local diff=0

    if [[ "$start_ts" =~ ^[0-9]+$ ]] && [[ "$end_ts" =~ ^[0-9]+$ ]] && (( end_ts >= start_ts )); then
        diff=$(( end_ts - start_ts ))
    fi

    if (( diff <= 0 )); then
        printf '小于 1 秒'
    elif (( diff < 60 )); then
        printf '%d 秒' "$diff"
    elif (( diff < 3600 )); then
        printf '%d 分 %d 秒' $(( diff / 60 )) $(( diff % 60 ))
    else
        printf '%d 小时 %d 分 %d 秒' $(( diff / 3600 )) $(( (diff % 3600) / 60 )) $(( diff % 60 ))
    fi
}

trim_text() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    printf '%s' "$s" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'
}

normalize_command() {
    local raw="${1:-}"
    raw="$(trim_text "$raw")"
    raw="${raw%%$'\n'*}"

    local first=""
    first="$(printf '%s' "$raw" | awk '{print $1}')"
    first="${first%%@*}"

    printf '%s' "$first"
}

send_reply() {
    local chat_id="$1"
    local title="$2"
    local body="$3"
    send_tg_to_chat "$chat_id" "$title" "$body" || true
}

append_elapsed_line() {
    local body="$1"
    local started="$2"
    local finished="$3"

    printf '%s\n\n本次耗时：%s' "$body" "$(format_elapsed "$started" "$finished")"
}

safe_check_all_health() {
    check_all_health || true
}

safe_check_emby_health() {
    check_emby_health || true
}

safe_check_pro189_health() {
    check_pro189_health || true
}

pause_guard_if_needed() {
    if guard_is_paused; then
        echo "already_paused"
        return 0
    fi

    pause_guard "tg_control_manual_operation" || true
    echo "paused_now"
    return 0
}

resume_guard_if_needed() {
    local mode="${1:-already_paused}"
    if [ "$mode" = "paused_now" ]; then
        resume_guard || true
    fi
}

build_help_body() {
    cat <<'EOF'
可用命令：

一、状态查询
/help
查看帮助菜单

/status
查看 Emby、189Pro、守护脚本的整体状态

/status_emby
只查看 Emby 当前状态

/status_189pro
只查看 189Pro 当前状态

二、手动操作
/restart_emby
手动重启 Emby 服务，并校验恢复结果

/restart_189pro
手动重启 189Pro 容器，并校验恢复结果

/restart_all
依次重启 Emby 和 189Pro，并返回整体结果

三、守护控制
/pause_guard
暂停守护脚本的自动恢复功能

/resume_guard
恢复守护脚本的自动恢复功能

说明：
1. 当前脚本按私聊场景设计
2. 建议只在私聊窗口发送命令
3. 所有执行类命令都会返回最终结果和本次耗时
4. 手动重启服务时，会临时暂停守护，避免和自动恢复冲突
EOF
}

build_status_reply() {
    local user_name="$1"
    local user_id="$2"
    cat <<EOF
发起人：${user_name} (${user_id})
请求时间：$(now_beijing)

$(full_status_summary)

总结：以上为 Emby、189Pro 和守护工具的当前整体状态。
EOF
}

build_emby_status_reply() {
    local user_name="$1"
    local user_id="$2"
    cat <<EOF
发起人：${user_name} (${user_id})
请求时间：$(now_beijing)

$(emby_summary)

总结：以上为 Emby 当前检测结果。
EOF
}

build_pro189_status_reply() {
    local user_name="$1"
    local user_id="$2"
    cat <<EOF
发起人：${user_name} (${user_id})
请求时间：$(now_beijing)

$(pro189_summary)

总结：以上为 189Pro 当前检测结果。
EOF
}

build_restart_emby_start_body() {
    local user_name="$1"
    local user_id="$2"
    local guard_mode="$3"

    cat <<EOF
发起人：${user_name} (${user_id})
开始时间：$(now_beijing)
守护状态处理：${guard_mode}

执行内容：
1. 暂停守护（如当前未暂停）
2. 重启 Emby 服务
3. 等待服务恢复
4. 重新校验 Emby 状态
5. 恢复守护（仅恢复本次命令暂停的守护）

请稍候，正在处理。
EOF
}

build_restart_pro189_start_body() {
    local user_name="$1"
    local user_id="$2"
    local guard_mode="$3"

    cat <<EOF
容器名称：${PRO189_CONTAINER_NAME}
发起人：${user_name} (${user_id})
开始时间：$(now_beijing)
守护状态处理：${guard_mode}

执行内容：
1. 暂停守护（如当前未暂停）
2. 重启 189Pro 容器
3. 等待容器恢复
4. 重新校验 189Pro 状态
5. 恢复守护（仅恢复本次命令暂停的守护）

请稍候，正在处理。
EOF
}

build_restart_all_start_body() {
    local user_name="$1"
    local user_id="$2"
    local guard_mode="$3"

    cat <<EOF
发起人：${user_name} (${user_id})
开始时间：$(now_beijing)
守护状态处理：${guard_mode}

执行内容：
1. 暂停守护（如当前未暂停）
2. 重启 Emby
3. 重启 189Pro
4. 重新校验整体状态
5. 恢复守护（仅恢复本次命令暂停的守护）

请稍候，正在处理。
EOF
}

build_restart_emby_done_body() {
    local user_name="$1"
    local user_id="$2"
    local result_text="$3"
    local guard_mode="$4"

    cat <<EOF
发起人：${user_name} (${user_id})
完成时间：$(now_beijing)
执行结果：${result_text}
守护状态处理：${guard_mode}

$(emby_summary)

总结：以上为 Emby 重启后的最新状态。
EOF
}

build_restart_pro189_done_body() {
    local user_name="$1"
    local user_id="$2"
    local result_text="$3"
    local guard_mode="$4"

    cat <<EOF
容器名称：${PRO189_CONTAINER_NAME}
发起人：${user_name} (${user_id})
完成时间：$(now_beijing)
执行结果：${result_text}
守护状态处理：${guard_mode}

$(pro189_summary)

总结：以上为 189Pro 重启后的最新状态。
EOF
}

build_restart_all_done_body() {
    local user_name="$1"
    local user_id="$2"
    local result_text="$3"
    local guard_mode="$4"

    cat <<EOF
发起人：${user_name} (${user_id})
完成时间：$(now_beijing)
执行结果：${result_text}
守护状态处理：${guard_mode}

$(full_status_summary)

总结：以上为全部服务重启后的整体状态。
EOF
}

build_pause_guard_body() {
    local user_name="$1"
    local user_id="$2"

    cat <<EOF
发起人：${user_name} (${user_id})
完成时间：$(now_beijing)

自动恢复功能：已暂停
状态查询功能：可继续使用
TG 控制功能：可继续使用

总结：后续异常不会自动触发恢复，请按需手动处理。
EOF
}

build_resume_guard_body() {
    local user_name="$1"
    local user_id="$2"

    cat <<EOF
发起人：${user_name} (${user_id})
完成时间：$(now_beijing)

自动恢复功能：已恢复
状态查询功能：可继续使用
TG 控制功能：可继续使用

总结：后续异常将重新允许自动恢复。
EOF
}

describe_guard_mode() {
    local mode="$1"
    case "$mode" in
        paused_now) printf '本次命令已临时暂停守护，结束后会自动恢复' ;;
        already_paused) printf '守护原本已暂停，本次命令不会自动恢复守护' ;;
        *) printf '未知' ;;
    esac
}

handle_command() {
    local chat_id="$1"
    local user_id="$2"
    local user_name="$3"
    local raw_text="$4"

    local cmd=""
    cmd="$(normalize_command "$raw_text")"

    local started=0
    local finished=0
    local body=""
    local guard_mode=""
    started="$(now_epoch)"

    case "$cmd" in
        /help|/start)
            finished="$(now_epoch)"
            body="$(build_help_body)"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【帮助中心】可用命令如下" "$body"
            ;;

        /status)
            safe_check_all_health
            finished="$(now_epoch)"
            body="$(build_status_reply "$user_name" "$user_id")"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【系统总状态】当前检测结果" "$body"
            ;;

        /status_emby)
            safe_check_emby_health
            finished="$(now_epoch)"
            body="$(build_emby_status_reply "$user_name" "$user_id")"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【Emby 状态】当前检测结果" "$body"
            ;;

        /status_189pro)
            safe_check_pro189_health
            finished="$(now_epoch)"
            body="$(build_pro189_status_reply "$user_name" "$user_id")"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【189Pro 状态】当前检测结果" "$body"
            ;;

        /restart_emby)
            guard_mode="$(pause_guard_if_needed)"
            send_reply "$chat_id" "【执行中】正在重启 Emby" "$(build_restart_emby_start_body "$user_name" "$user_id" "$(describe_guard_mode "$guard_mode")")"

            if restart_emby manual "tg:${user_id}"; then
                safe_check_emby_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_emby_done_body "$user_name" "$user_id" "成功" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行成功】Emby 重启完成" "$body"
            else
                safe_check_emby_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_emby_done_body "$user_name" "$user_id" "失败" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行失败】Emby 重启失败" "$body"
            fi
            ;;

        /restart_189pro)
            guard_mode="$(pause_guard_if_needed)"
            send_reply "$chat_id" "【执行中】正在重启 189Pro" "$(build_restart_pro189_start_body "$user_name" "$user_id" "$(describe_guard_mode "$guard_mode")")"

            if restart_pro189 manual "tg:${user_id}"; then
                safe_check_pro189_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_pro189_done_body "$user_name" "$user_id" "成功" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行成功】189Pro 重启完成" "$body"
            else
                safe_check_pro189_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_pro189_done_body "$user_name" "$user_id" "失败" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行失败】189Pro 重启失败" "$body"
            fi
            ;;

        /restart_all)
            guard_mode="$(pause_guard_if_needed)"
            send_reply "$chat_id" "【执行中】正在重启全部服务" "$(build_restart_all_start_body "$user_name" "$user_id" "$(describe_guard_mode "$guard_mode")")"

            if restart_all_services "tg:${user_id}"; then
                safe_check_all_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_all_done_body "$user_name" "$user_id" "成功" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行成功】全部服务重启完成" "$body"
            else
                safe_check_all_health
                resume_guard_if_needed "$guard_mode"
                finished="$(now_epoch)"
                body="$(build_restart_all_done_body "$user_name" "$user_id" "失败" "$(describe_guard_mode "$guard_mode")")"
                body="$(append_elapsed_line "$body" "$started" "$finished")"
                send_reply "$chat_id" "【执行失败】全部服务未完全恢复" "$body"
            fi
            ;;

        /pause_guard)
            pause_guard "tg:${user_id}" || true
            log_ctrl "WARN" "守护已暂停 | 用户=${user_name} (${user_id})"
            finished="$(now_epoch)"
            body="$(build_pause_guard_body "$user_name" "$user_id")"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【已执行】守护功能已暂停" "$body"
            ;;

        /resume_guard)
            resume_guard || true
            log_ctrl "INFO" "守护已恢复 | 用户=${user_name} (${user_id})"
            finished="$(now_epoch)"
            body="$(build_resume_guard_body "$user_name" "$user_id")"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【已执行】守护功能已恢复" "$body"
            ;;

        *)
            finished="$(now_epoch)"
            body="收到内容：${raw_text}

当前不支持该命令。
请发送 /help 查看可用命令。"
            body="$(append_elapsed_line "$body" "$started" "$finished")"
            send_reply "$chat_id" "【未知命令】未识别输入内容" "$body"
            ;;
    esac
}

init_suite

if ! is_true "$TG_CONTROL_ENABLE"; then
    log_ctrl "WARN" "TG 控制器已在配置中关闭，程序直接退出。"
    exit 0
fi

if ! telegram_configured; then
    log_ctrl "ERROR" "TG 配置不完整，TG 控制器无法启动。"
    exit 1
fi

acquire_singleton_lock "$TG_LOCK_FILE" "$COMPONENT_NAME"
safe_check_all_health
log_ctrl "INFO" "TG 控制器已启动，开始监听 Telegram 命令。"

OFFSET="$(load_tg_offset)"
[[ "$OFFSET" =~ ^[0-9]+$ ]] || OFFSET=0

while true; do
    raw="$(telegram_get_updates "$OFFSET" || true)"
    if [ -z "$raw" ]; then
        sleep 2
        continue
    fi

    lines="$(printf '%s' "$raw" | parse_updates_to_lines || true)"
    if [ -z "$lines" ]; then
        sleep 1
        continue
    fi

    while IFS=$'\t' read -r update_id chat_id user_id text_b64 chat_type name_b64; do
        [ -n "$update_id" ] || continue
        OFFSET=$(( update_id + 1 ))
        save_tg_offset "$OFFSET"

        text="$(decode_b64 "$text_b64")"
        user_name="$(decode_b64 "$name_b64")"
        text="${text//$'\r'/}"

        log_ctrl "INFO" "收到命令 | update=${update_id} | chat=${chat_id} | 类型=${chat_type} | 用户=${user_name} (${user_id}) | 内容=${text}"

        if [ "${chat_type:-}" != "private" ]; then
            log_ctrl "WARN" "忽略非私聊命令 | chat=${chat_id} | 类型=${chat_type} | 用户=${user_id}"
            continue
        fi

        if ! authorized_chat "$chat_id"; then
            log_ctrl "WARN" "拒绝命令：chat_id 未授权 | chat=${chat_id} | 用户=${user_id}"
            continue
        fi

        if ! authorized_user "$user_id"; then
            log_ctrl "WARN" "拒绝命令：user_id 未授权 | chat=${chat_id} | 用户=${user_id}"
            continue
        fi

        if [[ ! "$(normalize_command "$text")" =~ ^/ ]]; then
            continue
        fi

        if ! handle_command "$chat_id" "$user_id" "$user_name" "$text"; then
            log_ctrl "ERROR" "命令处理异常 | update=${update_id} | chat=${chat_id} | 用户=${user_name} (${user_id}) | 内容=${text}"
            send_reply "$chat_id" "【执行异常】命令处理失败" "命令：${text}
时间：$(now_beijing)

本次命令处理过程中发生异常，请查看服务端日志排查。"
        fi
    done <<< "$lines"
done
