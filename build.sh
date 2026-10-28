#!/bin/bash
# 一键编译 + 打包成 .app
#
#   ./build.sh                         # 本机架构，版本 1.0.0
#   VERSION=1.2.0 ./build.sh           # 指定版本号（写进 Info.plist 和 zip 名）
#   UNIVERSAL=1 ./build.sh             # arm64 + x86_64 通用二进制
#
# 产物：
#   build/IPASigner.app                  可直接 open
#   dist/IPASigner-<VERSION>-macOS.zip   可分发
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="IPASigner"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="dist"
ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-macOS.zip"
TARGET_MIN="macos13.0"
BIN="$APP/Contents/MacOS/$APP_NAME"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  local arch="$1" out="$2"
  echo "==> 编译 $arch"
  swiftc -O -parse-as-library \
    -target "${arch}-apple-${TARGET_MIN}" \
    -o "$out" \
    Sources/*.swift \
    -framework SwiftUI -framework AppKit
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
  TMP=$(mktemp -d)
  compile arm64 "$TMP/arm64"
  compile x86_64 "$TMP/x86_64"
  echo "==> lipo 合并成通用二进制"
  lipo -create -output "$BIN" "$TMP/arm64" "$TMP/x86_64"
  rm -rf "$TMP"
else
  compile "$(uname -m)" "$BIN"
fi

echo "==> 打包 Info.plist（版本 ${VERSION}）"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/appicon.png "$APP/Contents/Resources/appicon.png"

echo "==> 本地签名（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo "==> 自检"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "    codesign --verify 通过"
else
  echo "    (codesign 校验未通过；ad-hoc 自签一般不影响本地运行)"
fi

echo "==> 打可分发压缩包"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/${APP_NAME}-"*"-macOS.zip"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

echo
echo "产物:"
echo "  $APP   ($(du -sh "$APP" | cut -f1))"
echo "  $ZIP   ($(du -sh "$ZIP" | cut -f1))"
echo "  架构: $(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
