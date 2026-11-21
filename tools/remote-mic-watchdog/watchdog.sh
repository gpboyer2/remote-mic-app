#!/bin/bash
# miremote-watchdog —— 检测 MiRemoteV 虚拟声卡是否还在环回；卡死则分级恢复。
#
# 设计原则：
#   1. 只做检测与编排，音频动作交给 miremote-probe 与 miremote-level；
#   2. 恢复分级：L2 重启驱动宿主 → L3 重启 coreaudiod（都需一次 sudo 安装的 helper）；
#   3. 每次动作都落结构化日志，下次一眼能看出「什么时候、因为什么、做了什么」。
#
# 为什么不再用 ffmpeg 判环回：它的 avfoundation 输入对这两个虚拟设备一律报 -91dB，
# 环回健康时也是假阴性；装了 helper 后会照着假阴性去杀驱动宿主，等于制造故障。
# miremote-level 走 AVAudioEngine，与豆包读设备是同一条路径。
set -u

BASE="$HOME/Library/Application Support/RemoteMicWatchdog"
BIN="$BASE/bin"
LOG="$BASE/watchdog.log"
STATE="$BASE/state.json"
PROBE="$BIN/miremote-probe"
LEVEL="$BIN/miremote-level"
UNMUTE="$BIN/miremote-unmute"
DEVICE_UID="MiRemoteV2ch_UID"
HELPER="/usr/local/bin/miremote-audio-fix"
COOLDOWN_SECONDS=1800   # 两次 root 级修复之间至少 30 分钟
THRESHOLD_DB=-50        # 回读峰值高于这个值才算「环回正常」

mkdir -p "$BASE"
# shellcheck source=lib-lock.sh
source "$BASE/lib-lock.sh"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

# 日志轮转：超过 1MB 留最后 2000 行
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 返回 0=正常，1=卡死，2=环境异常（找不到设备/工具/权限）
check_loopback() {
  local tmp db
  [ -x "$PROBE" ] || { echo "no_probe"; return 2; }
  [ -x "$LEVEL" ] || { echo "no_level_tool"; return 2; }

  tmp=$(mktemp /tmp/miremote-check.XXXXXX.json)
  # 先起录音，再写入测试音：反过来会漏掉前 0.4 秒
  "$LEVEL" "$DEVICE_UID" 3 > "$tmp" 2>/dev/null &
  local rec=$!
  sleep 0.4
  "$PROBE" "$DEVICE_UID" 1.5 0.5 >/dev/null 2>&1
  wait "$rec" 2>/dev/null

  db=$(sed -n 's/.*"db":\(-\{0,1\}[0-9.]*\).*/\1/p' "$tmp" | head -1)
  if [ -z "${db:-}" ]; then
    rm -f "$tmp"
    echo "no_measurement"; return 2
  fi
  rm -f "$tmp"

  # -170 以下只可能是「没有样本」，有样本的静音也会是约 -91 到 -120。
  # launchd 上下文没有麦克风权限时正是这个读数，若当成故障去恢复就是误杀。
  if awk -v p="$db" 'BEGIN{exit !(p>-170)}'; then :; else
    echo "unknown peak=${db}dB（无权限或设备侧无数据，不做恢复判定）"; return 2
  fi

  # awk 做浮点比较
  if awk -v p="$db" -v t="$THRESHOLD_DB" 'BEGIN{exit !(p>t)}'; then
    echo "ok peak=${db}dB"; return 0
  fi
  echo "silent peak=${db}dB"; return 1
}

last_root_fix() {
  [ -f "$STATE" ] && python3 - "$STATE" <<'PY' 2>/dev/null || echo 0
import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("lastRootFix", 0)))
except Exception:
    print(0)
PY
}

save_root_fix() {
  local now
  now=$(date +%s)
  printf '{"lastRootFix":%s,"lastFixAt":"%s"}\n' "$now" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$STATE"
}

restart_app() {
  local pid
  pid=$(pgrep -x RemoteMic | head -1)
  if [ -n "${pid:-}" ]; then
    kill "$pid" 2>/dev/null
    sleep 2
  fi
  open "/Applications/Remote Mic.app" 2>/dev/null
  sleep 4
}

main() {
  local result rc

  # 第一步永远先看静音状态位：它不需要音频权限，也是 2026-11/19 两次事故的真实根因。
  [ -x "$UNMUTE" ] && "$UNMUTE" "$DEVICE_UID" input >/dev/null 2>&1

  result=$(check_loopback); rc=$?

  if [ "$rc" -eq 0 ]; then
    log "CHECK ok $result"
    exit 0
  fi
  if [ "$rc" -eq 2 ]; then
    log "CHECK environment_error $result"
    exit 2
  fi

  # 不再做「重启客户端」这一步：
  # 实测无效，而且每次重建 IOContext 都会在驱动宿主里新增 Mach port，
  # 正好加剧根因（端口泄漏）。
  log "CHECK failed $result -> 需要 root 级恢复"

  if [ ! -x "$HELPER" ]; then
    log "RECOVER skipped reason=helper_not_installed hint='sudo $BASE/install-helper.sh'"
    exit 1
  fi
  if ! sudo -n "$HELPER" driver >/dev/null 2>&1; then
    log "RECOVER skipped reason=sudo_not_configured"
    exit 1
  fi

  local last now
  last=$(last_root_fix); now=$(date +%s)
  if [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]; then
    log "RECOVER skipped reason=cooldown elapsed=$((now - last))s"
    exit 1
  fi

  # L2：只杀 MiRemoteV 的驱动宿主，爆炸半径小于 coreaudiod
  log "RECOVER L2 restart driver"
  save_root_fix
  sleep 5
  result=$(check_loopback); rc=$?
  if [ "$rc" -eq 0 ]; then
    log "RECOVER L2 ok $result"
    exit 0
  fi
  log "RECOVER L2 failed $result -> L3 restart coreaudiod"

  # L3：重启 coreaudiod（全系统音频中断 1-2 秒）
  sudo -n "$HELPER" coreaudiod >/dev/null 2>&1
  sleep 8
  result=$(check_loopback); rc=$?
  if [ "$rc" -eq 0 ]; then
    log "RECOVER L3 ok $result"
    exit 0
  fi
  log "RECOVER L3 failed $result -> 建议重启机器"
  exit 1
}

if ! acquire_single_instance "$BASE" watch; then
  log "SKIP 已有实例在跑，跳过本轮（避免两个实例抢设备造成假阴性）"
  exit 0
fi

main "$@"
