#!/bin/bash
# 一次性安装：把「重启 coreaudiod」固化成一个只能做这一件事的 root helper，
# 并给当前用户配一条 sudoers 白名单，之后 watchdog 可以免密自动调用。
#
# 安全边界：
#   - helper 不接受任何参数，命令写死，不能被当成通用提权入口；
#   - sudoers 只放行这一个绝对路径；
#   - 安装后可随时用 uninstall-helper.sh 撤销。
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行：sudo \"$0\""
  exit 1
fi

TARGET_USER="${SUDO_USER:-peng}"
BASE="/Users/$TARGET_USER/Library/Application Support/RemoteMicWatchdog"
HELPER="/usr/local/bin/miremote-audio-fix"
SUDOERS="/etc/sudoers.d/miremote-audio"

echo "==> 1/2 安装 root helper"
install -d -o root -g wheel -m 755 /usr/local/bin
cat > "$HELPER" <<'HELPER_EOF'
#!/bin/bash
# 只做两件固定的事，参数白名单，不接受任意命令。
set -u
case "${1:-}" in
  driver)
    exec /usr/bin/pkill -TERM -f "Core Audio Driver \(MiRemoteV2ch.driver\)"
    ;;
  coreaudiod)
    exec /usr/bin/killall coreaudiod
    ;;
  *)
    echo "usage: miremote-audio-fix driver|coreaudiod" >&2
    exit 2
    ;;
esac
HELPER_EOF
chown root:wheel "$HELPER"
chmod 755 "$HELPER"

echo "==> 2/2 配置 sudoers 白名单"
# 先写临时文件并用 visudo 校验，通过后才落到 /etc/sudoers.d，
# 否则一条写错的规则会让整台机器的 sudo 全部失效。
SUDO_TMP="$(mktemp)"
echo "$TARGET_USER ALL=(root) NOPASSWD: $HELPER" > "$SUDO_TMP"
if ! visudo -cf "$SUDO_TMP" >/dev/null 2>&1; then
  echo "❌ sudoers 规则校验失败，已中止（未改动系统）"
  rm -f "$SUDO_TMP"
  exit 1
fi
install -m 440 -o root -g wheel "$SUDO_TMP" "$SUDOERS"
rm -f "$SUDO_TMP"

echo ""
echo "✅ root helper 安装完成"
echo "   只做两件事：重启 MiRemoteV 驱动宿主 / 重启 coreaudiod"
echo "   撤销：sudo bash \"$BASE/uninstall-helper.sh\""
echo ""
echo "下一步（不需要 root，安装用户级定时任务）："
echo "   bash \"$(cd "$(dirname "$0")" && pwd)/install.sh\""
