#!/bin/bash
# 一键编译 SayFlow 输入法 → 组装 App → 签名（ad-hoc + Hardened Runtime + App Sandbox）→ 打成 DMG
#
# 用法（在仓库根目录）：./scripts/build.sh
# 只需要「命令行工具」（xcode-select --install），不需要完整 Xcode。
# vendor/rime 里有 librime 静态库时编出完整打字版；没有时编出「英文直通」版（语音、改写照常）。

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SayFlow"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME-$VERSION-arm64.dmg"
ZIP="$BUILD_DIR/$APP_NAME-$VERSION-arm64.zip"

step() { echo; echo "==> $*"; }

step "1/5 检查工具"
command -v swift >/dev/null 2>&1 || { echo "缺少 swift，请先运行：xcode-select --install"; exit 1; }
swift --version 2>&1 | head -1
if [ -f vendor/rime/lib/librime.a ]; then echo "打字引擎：librime（vendor/rime）"; else echo "打字引擎：未加入（英文直通版）"; fi

step "2/5 编译（release, arm64）"
swift build -c release --arch arm64 --product "$APP_NAME"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

step "3/5 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
TMP_ICON="$BUILD_DIR/icon-tmp"
rm -rf "$TMP_ICON" && mkdir -p "$TMP_ICON"
sips -s format tiff Resources/menu16.png --out "$TMP_ICON/menu16.tiff" >/dev/null
sips -s format tiff Resources/menu32.png --out "$TMP_ICON/menu32.tiff" >/dev/null
tiffutil -cathidpicheck "$TMP_ICON/menu16.tiff" "$TMP_ICON/menu32.tiff" -out "$APP/Contents/Resources/MenuIcon.tiff" >/dev/null
rm -rf "$TMP_ICON"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$APP/Contents/Resources/"
if [ -d vendor/rime-data ]; then
  ditto vendor/rime-data "$APP/Contents/Resources/rime-data"
  echo "已放入词库和方案：$(du -sh "$APP/Contents/Resources/rime-data" | cut -f1)"
fi

step "4/5 签名（ad-hoc + Hardened Runtime + App Sandbox）"
codesign --force --options runtime --entitlements Resources/SayFlow.entitlements --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

step "5/5 打包 DMG 和 zip"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s "/Library/Input Methods" "$STAGE/输入法文件夹（把 SayFlow 拖到这里）"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "完成："
echo "  安装包：$DMG"
echo "  App 压缩包（交给安全团队）：$ZIP"
shasum -a 256 "$DMG" "$ZIP"
echo
echo "下一步：./scripts/selfcheck.sh  生成安全自查结果"
