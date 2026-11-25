#!/bin/bash
# lib.sh —— remote-mic-watchdog 的公共函数库（唯一定义处）。
#
# 为什么收口到这里：此前 log/uptime/空闲/状态文件/日志轮转/单实例锁
# 在 watchdog.sh 与 mute-guard.sh 里各写一份，改一处漏一处——
# 「豆包 idle 误判」「整数比较崩溃」这两个坑都是复制粘贴分叉出来的。
#
# 设计原则：
#   1. 只放与业务无关的通用能力：进程、时间、状态文件、锁、日志；
#      任何「豆包 / 虚拟声卡 / Clash」的字面量都不许进来；
#   2. 每个函数都返回明确状态码，调用方按码分支，不靠解析字符串猜；
#   3. 拿不到数据时返回「未知」，绝不用默认值假装成功（0 秒不等于空闲）。
#
# 用法：
#   source "$BASE/lib.sh"
#   log_timed "$LOG" "TAG message"
#   pid=$(proc_pid DoubaoIme) || ...
set -u

# ---- 日志 ----

# 带本地时区时间戳追加一行日志。stdout 保持安静，交给 launchd 的 *.stdout.log 兜底。
log_timed() {
  local logfile="$1"; shift
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$logfile"
}

# 超过 $max_bytes 时保留最后 $keep_lines 行。轮转失败不致命，原日志保持可读即可。
rotate_log() {
  local logfile="$1" max_bytes="${2:-1048576}" keep_lines="${3:-2000}" size
  [ -f "$logfile" ] || return 0
  size=$(stat -f%z "$logfile" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$max_bytes" ] || return 0
  tail -n "$keep_lines" "$logfile" > "$logfile.tmp" 2>/dev/null &&
    mv -f "$logfile.tmp" "$logfile" 2>/dev/null
}

# ---- 进程与时间 ----

# 精确按进程名取 PID（不接受宽松匹配，避免误伤同名子进程）。
proc_pid() {
  local name="$1" pid
  pid=$(pgrep -x "$name" 2>/dev/null | head -1)
  [ -n "${pid:-}" ] && printf '%s\n' "$pid"
}

# 进程已运行秒数。取不到时返回 1，调用方必须当成「未知」而不是 0：
# 把未知当 0 会让「冷启动宽限期」判定永远成立，自愈逻辑直接瘫痪。
proc_uptime_seconds() {
  local pid="$1" et
  et=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "${et:-}" ] || return 1
  parse_etime_seconds "$et"
}

# 把 ps 的 etime 格式（[[dd-]hh:]mm:ss）换算成秒。
parse_etime_seconds() {
  local s="$1" days=0 h m sec
  case "$s" in '') return 1 ;; esac
  if printf '%s' "$s" | grep -q -- '-'; then
    days=${s%%-*}
    s=${s#*-}
  fi
  IFS=':' read -r -a _etime_parts <<< "$s"
  case ${#_etime_parts[@]} in
    3) h=${_etime_parts[0]}; m=${_etime_parts[1]}; sec=${_etime_parts[2]} ;;
    2) h=0; m=${_etime_parts[0]}; sec=${_etime_parts[1]} ;;
    *) return 1 ;;
  esac
  case "$days$h$m$sec" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( 10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$sec ))
}

# HID 空闲秒数。读不到返回 1。
# 超过 60 秒的输出交给 awk 的 double 处理：HIDIdleTime 是纳秒级的 18 位数，
# 先除后转 int 会丢精度，被误判成「正在操作」而把自愈挡在外面。
hid_idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '
    /HIDIdleTime/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "=") { v = $(i + 1); sub(/"/, "", v); gsub(/"/, "", v); print v / 1e9; hit = 1; exit }
      }
    }
    END { if (!hit) exit 1 }
  '
}

# ---- 状态文件 ----

# 读一个非负整数状态；文件缺失或内容损坏时返回 $default，不返回错误串。
state_read_int() {
  local file="$1" default="${2:-0}" v
  v=""
  [ -f "$file" ] && v=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$default" ;; *) printf '%s\n' "$v" ;; esac
}

state_write_int() {
  local file="$1" value="$2"
  printf '%s\n' "$value" > "$file" 2>/dev/null
}

# ---- 单实例锁 ----
#
# 为什么需要：launchd 的 RunAtLoad 与 StartInterval 会撞上手动执行，
# 两个实例同时开 AVAudioEngine 会互相抢设备，录音方拿不到数据，
# 于是「环回正常」被误判成「环回坏了」，接着就会照着假阴性去恢复。
#
# 为什么不用 flock：macOS 不自带 flock(1)。mkdir 的原子性足够，配合陈旧锁超时即可。
acquire_single_instance() {
  local base="$1" name="$2" max_wait="${3:-20}"
  local lockdir="$base/.lock-$name" waited=0 age

  # 退出时释放：路径必须现在展开成字面量，EXIT 时函数已返回、local 不在作用域。
  # trap 接的是**保留的父 shell 状态**，即使 acquire 在 main 的子 shell 外调用也不会丢。
  # shellcheck disable=SC2064  # 要的就是立即展开
  trap "rm -rf '$lockdir' 2>/dev/null || true" EXIT

  while ! mkdir "$lockdir" 2>/dev/null; do
    # 陈旧锁回收：进程被 SIGKILL（sudo kill coreaudiod 这类）时 trap 不会执行，
    # 锁目录会原地留下，此后每轮都拿到锁就永远 SKIP —— 自愈等于停摆。
    # 判据取锁持有者是否还活着；拿不到 owner 时退回按 mtime 超时。
    local owner_file="$lockdir/owner" owner age
    if [ -d "$lockdir" ]; then
      owner=""
      [ -f "$owner_file" ] && owner=$(cat "$owner_file" 2>/dev/null)
      if [ -n "${owner:-}" ]; then
        if ! kill -0 "$owner" 2>/dev/null; then
          rm -rf "$lockdir"
          continue
        fi
      else
        # 旧格式锁目录（无 owner 文件）：按 mtime 判陈旧
        age=$(( $(date +%s) - $(stat -f%m "$lockdir" 2>/dev/null || echo 0) ))
        if [ "$age" -gt 300 ]; then
          rm -rf "$lockdir"
          continue
        fi
      fi
    fi
    waited=$((waited + 1))
    [ "$waited" -ge "$max_wait" ] && return 1
    sleep 1
  done

  # 记录持有者 PID，供下一轮判断锁是否已成僵尸
  printf '%s\n' "$$" > "$lockdir/owner" 2>/dev/null || true

  return 0
}
