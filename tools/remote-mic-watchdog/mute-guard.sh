#!/bin/bash
# 虚拟声卡静音守卫
#
# 为什么需要它：MiRemoteV 是回环虚拟声卡，被静音（特别是输入侧）时，
# RemoteMic 写进去的语音读不出来，豆包能弹出语音浮窗、能联网，却只出输入法不出字。
# 而 macOS 会把设备静音状态持久化在 /Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist，
# 重启后 coreaudiod 按那份状态恢复——于是每次重启都复发。
#
# 职责边界：
#   - 只解除静音，不改音量、不碰物理设备、不动默认设备；
#   - 只在真有变化时写日志，避免每 60 秒刷一行；
#   - 命中设备写死，不接受参数，不能当成通用音频改动工具。
#
# 通用能力（日志、轮转、锁、状态文件）一律走 lib.sh，与 watchdog.sh 共用一份实现。
set -u

BASE="$HOME/Library/Application Support/RemoteMicWatchdog"
BIN="$BASE/bin/miremote-unmute"
LOG="$BASE/mute-guard.log"
STATE="$BASE/mute-guard.state"
DEVICES=("MiRemoteV2ch_UID" "BlackHole2ch_UID" "OrayVirtualAudioDevice_UID")

mkdir -p "$BASE"
# shellcheck source=lib.sh
source "$BASE/lib.sh"
log() { log_timed "$LOG" "$*"; }

[ -x "$BIN" ] || { log "SKIP 工具缺失 path=$BIN"; exit 2; }

if ! acquire_single_instance "$BASE" mute; then
  log "SKIP 已有守卫在跑"
  exit 0
fi

rotate_log "$LOG" 262144 1000

changed=""
for uid in "${DEVICES[@]}"; do
  out=$("$BIN" "$uid" 2>/dev/null)
  case "$out" in
    *not_found*) continue ;;
  esac
  # 只有「解除前是静音」才算一次真实修复
  if printf '%s\n' "$out" | grep -qE 'before=1'; then
    changed="$changed | $uid -> $out"
  fi
done

if [ -n "$changed" ]; then
  log "UNMUTE$changed"
  # 记录连续命中，便于看出是「一次性残留」还是「有进程在反复静音」
  hits=$(state_read_int "$STATE" 0)
  hits=$((hits + 1))
  state_write_int "$STATE" "$hits"
  [ "$hits" -ge 3 ] && log "REPEAT 已累计解除 $hits 次，说明有进程在反复静音虚拟声卡，需要查来源"
fi

exit 0
