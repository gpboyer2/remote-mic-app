#!/bin/bash
# 统一编译远程麦的运维小工具。
#
# 为什么要有这个脚本：探针和静音工具共用 CoreAudioDevice.swift，
# 各自手工 swiftc 很容易漏文件、编出「能跑但与源码不同步」的二进制。
# 这里只有一条编译路径，产物固定落在 bin/。
set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:-bin}"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
TARGET="${TARGET:-arm64-apple-macosx13.0}"

[ -d "$SDK" ] || { echo "❌ 找不到 SDK：$SDK" >&2; exit 1; }
mkdir -p "$OUT"

compile() {
  local name="$1"; shift
  echo "==> 编译 $name"
  # shellcheck disable=SC2086
  swiftc -sdk "$SDK" -target "$TARGET" "$@" -o "$OUT/$name"
}

compile miremote-probe  CoreAudioDevice.swift probe.swift
compile miremote-unmute CoreAudioDevice.swift unmute.swift
compile miremote-level  CoreAudioDevice.swift level.swift

chmod 755 "$OUT/miremote-probe" "$OUT/miremote-unmute" "$OUT/miremote-level"
echo "✅ 产物："
ls -l "$OUT/miremote-probe" "$OUT/miremote-unmute"