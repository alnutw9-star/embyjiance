#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
pkill -9 -f "$BASE_DIR/emby_guard.sh" || true
pkill -9 -f "$BASE_DIR/tg_control.sh" || true
echo "已停止 emby_guard.sh 与 tg_control.sh"
