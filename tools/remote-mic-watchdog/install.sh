#!/bin/bash
# 安装远程麦的用户级运维任务（不需要 root）。
#
# 职责：
#   1. 用 build.sh 统一编译测探针与静音工具；
#   2. 把脚本、源码、launchd 模板部署到运行时目录
#      ~/Library/Application Support/RemoteMicWatchdog；
#   3. 安装并加载两个 LaunchAgent：
#      - muted-guard：每 60 秒检查虚拟声卡是否被静音（重启后自动恢复）；
#      - watchdog：每 10 分钟检查环回是否还通（需要 root helper 才能做恢复）。
#
# root 级的「重启驱动宿主 / coreaudiod」不在这里，单独跑 install-helper.sh。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/Library/Application Support/RemoteMicWatchdog"
AGENTS="$HOME/Library/LaunchAgents"
CURRENT_UID="$(id -u)"
LABELS=(com.peng.miremote-mute-guard com.peng.miremote-watchdog)
FILES=(build.sh lib.sh watchdog.sh mute-guard.sh install-helper.sh uninstall-helper.sh)
SWIFT_FILES=(CoreAudioDevice.swift probe.swift unmute.swift level.swift)

mkdir -p "$BASE/bin" "$BASE/launchd" "$AGENTS"

echo "==> 1/3 编译工具"
bash "$SRC/build.sh" "$BASE/bin"

echo "==> 2/3 部署脚本与模板"
for f in "${FILES[@]}"; do
  cp "$SRC/$f" "$BASE/$f"
done
for f in "${SWIFT_FILES[@]}"; do
  # 源码也要落地：换机器或排查时，运行时目录能独立构建，不依赖这份仓库
  cp "$SRC/$f" "$BASE/$f"
done
cp "$SRC/launchd/"*.plist "$BASE/launchd/"
chmod 755 "$BASE"/*.sh

echo "==> 3/3 生成中文名外壳并加载 LaunchAgent"
# launchd 在「登录项 — 允许在后台」里显示的是可执行文件名。
# 直接跑 /bin/bash 会显示成 bash，用户会当成来路不明的脚本关掉。
write_wrapper() {
  local wrapper="$1" target="$2"
  printf '#!/bin/bash\n# 显示名外壳：让后台项显示中文名，而不是 bash。\nexec /bin/bash "%s"\n' "$BASE/$target" > "$BASE/$wrapper"
  chmod 755 "$BASE/$wrapper"
}
write_wrapper "虚拟声卡静音守卫" "mute-guard.sh"
write_wrapper "无线麦环回检测" "watchdog.sh"
for label in "${LABELS[@]}"; do
  target="$AGENTS/$label.plist"
  # 模板里的 __BASE__ 换成实际运行时路径，避免两处各写一份 plist
  sed "s|__BASE__|$BASE|g" "$SRC/launchd/$label.plist" > "$target"
  chmod 644 "$target"
  launchctl bootout "gui/$CURRENT_UID/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$CURRENT_UID" "$target"
  launchctl enable "gui/$CURRENT_UID/$label"
  echo "   已加载 $label"
done

echo ""
echo "✅ 安装完成"
echo "   静音守卫：每 60 秒，日志 $BASE/mute-guard.log"
echo "   环回检测：每 10 分钟，日志 $BASE/watchdog.log"
echo "   手动跑一次：bash \"$BASE/mute-guard.sh\""
echo "   需要 root 级恢复时另行执行：sudo bash \"$SRC/install-helper.sh\""