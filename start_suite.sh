#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$BASE_DIR/logs" "$BASE_DIR/run" "$BASE_DIR/tmp"
chmod +x "$BASE_DIR"/*.sh || true
nohup /bin/bash "$BASE_DIR/emby_guard.sh" >> "$BASE_DIR/logs/emby_guard.nohup.log" 2>&1 &
nohup /bin/bash "$BASE_DIR/tg_control.sh" >> "$BASE_DIR/logs/tg_control.nohup.log" 2>&1 &
echo "已启动 emby_guard.sh 与 tg_control.sh"
