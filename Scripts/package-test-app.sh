#!/bin/zsh
# Explicit opt-in test packaging; never used as a fallback by formal publishing.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${PROJECT_DIR}/Packaging/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${PROJECT_DIR}/Packaging/Info.plist")
OUTPUT_DMG="${PROJECT_DIR}/outputs/JingXu-${VERSION}-test.${BUILD}-macOS-arm64.dmg"
if [[ -n "${1:-}" ]]; then
  print -u2 "未知参数：$1"; exit 1
fi
[[ ! -e "$OUTPUT_DMG" && ! -e "${OUTPUT_DMG}.sha256" ]] || { print -u2 "测试产物已存在；请先归档或增加构建号。"; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 "只支持 Apple Silicon 构建。"; exit 1; }
PACKAGE_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jingxu-test.XXXXXX")
trap 'rm -rf "${PACKAGE_TEMP}"' EXIT
STAGING="${PACKAGE_TEMP}/image"
APP_DIR="${STAGING}/镜序.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cd "$PROJECT_DIR"
swift build -c release --product JingXuApp --arch arm64
cp .build/arm64-apple-macosx/release/JingXuApp "${APP_DIR}/Contents/MacOS/JingXuApp"
cp Packaging/Info.plist "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add JingXuReleaseChannel string 未公证测试版" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add NSHumanReadableCopyright string 未公证测试版 · 仅供测试" "${APP_DIR}/Contents/Info.plist"
zsh Scripts/build-icon.sh
cp Packaging/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp Packaging/TestUpgrade-zh-Hans.txt "${STAGING}/测试版安装说明.txt"
ln -s /Applications "${STAGING}/应用程序"
chmod 755 "${APP_DIR}/Contents/MacOS/JingXuApp"
codesign --force --options runtime --sign - --entitlements JingXu.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
hdiutil create -volname "镜序 ${VERSION} 测试版" -srcfolder "$STAGING" -format UDZO "${PACKAGE_TEMP}/test.dmg"
hdiutil verify "${PACKAGE_TEMP}/test.dmg"
mkdir -p outputs
cp -n "${PACKAGE_TEMP}/test.dmg" "$OUTPUT_DMG"
cd outputs
shasum -a 256 "${OUTPUT_DMG:t}" > "${OUTPUT_DMG:t}.sha256"
print "未公证测试版：${OUTPUT_DMG}"
