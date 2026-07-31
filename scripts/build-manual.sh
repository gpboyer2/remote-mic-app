#!/bin/zsh
# Manual build script for macOS 13 + Swift 5.8 compatibility
# Bypasses SPM since Xcode is not fully installed
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_NAME="RemoteMic"
DISPLAY_NAME="Remote Mic"
OUTPUT_DIR="$ROOT/dist"
BUILD_DIR="$ROOT/.manualbuild"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

AUDIO_GUARD_SRC="Sources/AudioExceptionGuard/AudioExceptionGuard.m"
AUDIO_GUARD_HDR="Sources/AudioExceptionGuard/include/AudioExceptionGuard.h"

echo "==> Compiling Objective-C AudioExceptionGuard module..."
clang -c -arch arm64 -isysroot "$SDK_PATH" \
    -I"$(dirname "$AUDIO_GUARD_HDR")" \
    -fobjc-arc \
    "$AUDIO_GUARD_SRC" -o "$BUILD_DIR/AudioExceptionGuard.o"

# Compile all .swift files together in a single pass
echo "==> Compiling all Swift sources together..."
SWIFT_FILES=(Sources/RemoteMic/*.swift)

# Create module cache directory
mkdir -p "$BUILD_DIR/.modulecache"

swiftc -o "$BUILD_DIR/$APP_NAME" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    -Xcc -fmodule-map-file="Sources/AudioExceptionGuard/include/module.modulemap" \
    -I "Sources/AudioExceptionGuard/include" \
    -module-cache-path "$BUILD_DIR/.modulecache" \
    -parse-as-library \
    "$BUILD_DIR/AudioExceptionGuard.o" \
    $SWIFT_FILES \
    -Xlinker -ObjC \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Foundation \
    -framework CoreBluetooth \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework IOKit \
    -framework CoreGraphics \
    -framework Carbon \
    -framework ApplicationServices \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Installing Info.plist..."
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Copying Resources..."
for f in "$ROOT/Resources/"*.png "$ROOT/Resources/"*.icns; do
    [ -f "$f" ] && cp "$f" "$APP_DIR/Contents/Resources/"
done

for loc in "$ROOT/Resources/"*.lproj; do
    [ -d "$loc" ] && cp -R "$loc" "$APP_DIR/Contents/Resources/"
done

for doc in README TECHNICAL TROUBLESHOOTING COPYRIGHT LOGO-LICENSE THIRD_PARTY_NOTICES; do
    [ -f "$ROOT/$doc.en.md" ] && cp "$ROOT/$doc.en.md" "$APP_DIR/Contents/Resources/$doc.md"
done

echo "==> Ad-hoc codesigning..."
codesign --force --sign - --timestamp=none \
    --requirements "=designated => identifier \"com.hd838a.RemoteMic\"" \
    "$APP_DIR/Contents/MacOS/$APP_NAME"

codesign --force --sign - --timestamp=none \
    --requirements "=designated => identifier \"com.hd838a.RemoteMic\"" \
    "$APP_DIR"

echo "==> Verifying..."
codesign --verify --deep --strict "$APP_DIR" 2>&1

echo ""
echo "✅ Build complete: $APP_DIR"
file "$APP_DIR/Contents/MacOS/$APP_NAME"

# Cleanup build dir
rm -rf "$BUILD_DIR"
