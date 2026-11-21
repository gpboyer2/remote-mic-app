#!/bin/bash
# 撤销 install-helper.sh 装的东西，恢复「没有 root 组件」的状态。
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "请用 sudo 运行"; exit 1; fi
TARGET_USER="${SUDO_USER:-peng}"
TARGET_UID="$(id -u "$TARGET_USER")"
launchctl bootout "gui/$TARGET_UID/com.peng.miremote-watchdog" 2>/dev/null || true
rm -f "/Users/$TARGET_USER/Library/LaunchAgents/com.peng.miremote-watchdog.plist"
rm -f /etc/sudoers.d/miremote-audio
rm -f /usr/local/bin/miremote-audio-fix
echo "✅ 已撤销（检测脚本与日志保留）"
