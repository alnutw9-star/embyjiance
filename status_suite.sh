#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== emby_guard.sh ==="
ps -ef | grep "$BASE_DIR/emby_guard.sh" | grep -v grep || true
echo
echo "=== tg_control.sh ==="
ps -ef | grep "$BASE_DIR/tg_control.sh" | grep -v grep || true
