#!/usr/bin/env zsh
set -euo pipefail

# ============================================================
# dev-build.sh — 开发模式增量构建并启动 RemoteMic
#
# 用法：
#   ./script/dev-build.sh          # 构建并启动
#   ./script/dev-build.sh --build  # 只构建不启动
#
# 直接用 swiftc 编译，不依赖 swift build（SPM），绕过
# Command Line Tools 缺少 PlatformPath 导致 xcrun 报错的问题。
# ============================================================

ROOT="${0:A:h:h}"
APP_BUNDLE="$ROOT/dist/Remote Mic.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/RemoteMic"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk"
OBJ_DIR="/tmp/RemoteMic-build"
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# ── 1. 杀掉旧进程 ──
pkill -x RemoteMic >/dev/null 2>&1 || true
sleep 0.3

# ── 2. 编译 C 库 ──
echo "🔨 编译 AudioExceptionGuard…"
mkdir -p "$OBJ_DIR"
clang -c -O -target arm64-apple-macosx13.0 \
  -isysroot "$SDK" \
  -I "$ROOT/Sources/AudioExceptionGuard/include" \
  "$ROOT/Sources/AudioExceptionGuard/AudioExceptionGuard.m" \
  -o "$OBJ_DIR/AudioExceptionGuard.o" 2>&1
ar rcs "$OBJ_DIR/libAudioExceptionGuard.a" "$OBJ_DIR/AudioExceptionGuard.o"

# ── 3. 编译 Swift 源文件 ──
echo "🔨 编译 Swift 源文件…"
SDKROOT="$SDK" swiftc -O \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK" \
  -I "$ROOT/Sources/AudioExceptionGuard/include" \
  -framework AppKit -framework SwiftUI -framework CoreBluetooth \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
  -framework IOKit -framework Carbon -framework CoreGraphics \
  -framework ApplicationServices \
  $ROOT/Sources/RemoteMic/*.swift \
  "$OBJ_DIR/libAudioExceptionGuard.a" \
  -o "$OBJ_DIR/RemoteMic" \
  -emit-executable 2>&1

if [[ $? -ne 0 ]]; then
    echo "❌ 编译失败"
    exit 1
fi

# ── 4. 替换二进制 ──
echo "📦 替换二进制…"
strip -S -x "$OBJ_DIR/RemoteMic"
ditto --norsrc --noextattr --noqtn --noacl \
  "$OBJ_DIR/RemoteMic" "$APP_BINARY"

# 如果有 Sparkle framework，重新签名；否则只签主二进制
if [[ -d "$SPARKLE_FW" ]]; then
    codesign --force --options runtime --timestamp=none --sign - \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null
    codesign --force --options runtime --timestamp=none --sign - \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null
    codesign --force --options runtime --timestamp=none --sign - \
      "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null
    codesign --force --options runtime --timestamp=none --sign - \
      "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null
    codesign --force --options runtime --timestamp=none --sign - \
      "$SPARKLE_FW" 2>/dev/null
fi

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Contents/Info.plist")"
codesign --force --options runtime --timestamp=none \
  --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP_BUNDLE" 2>&1

echo "✅ 构建完成"

# ── 5. 启动 ──
if [[ "${1:-}" == "--build" ]]; then
    echo "   产物：$APP_BUNDLE"
else
    echo "🚀 启动应用…"
    /usr/bin/open -n "$APP_BUNDLE"
    echo "✅ 已启动"
fi
