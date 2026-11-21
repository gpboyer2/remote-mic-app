#!/bin/bash
# 单实例锁 —— 给会占用虚拟声卡的脚本用。
#
# 为什么需要：launchd 的 RunAtLoad 与 StartInterval 会撞上手动执行，
# 两个实例同时开 AVAudioEngine 会互相抢设备，录音方拿不到数据，
# 于是「环回正常」被误判成「环回坏了」，接着就会照着假阴性去恢复。
#
# 为什么不用 flock：macOS 不自带 flock(1)。mkdir 的原子性足够，配合陈旧锁超时即可。
#
# 用法：
#   source "$BASE/lib-lock.sh"
#   acquire_single_instance "$BASE" watch || { echo "已有实例在跑"; exit 0; }
acquire_single_instance() {
  local base="$1" name="$2" max_wait="${3:-20}"
  LOCKDIR="$base/.lock-$name"
  local waited=0 age

  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    # 陈旧锁：进程被强杀时 trap 不会执行，超过 5 分钟的锁视为残留
    if [ -d "$LOCKDIR" ]; then
      age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR" 2>/dev/null || echo 0) ))
      if [ "$age" -gt 300 ]; then
        rmdir "$LOCKDIR" 2>/dev/null || true
        continue
      fi
    fi
    waited=$((waited + 1))
    [ "$waited" -ge "$max_wait" ] && return 1
    sleep 1
  done

  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  return 0
}