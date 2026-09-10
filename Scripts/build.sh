#!/bin/zsh
# The same validation, compilation and packaging entry point locally and in CI.
set -euo pipefail
# The CI credentials wrapper uses 077; distributable app directories must remain
# readable after installation by a different user.
umask 022
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
MODE="${1:-check}"
[[ $# -le 1 && "$MODE" == (check|adhoc|release) ]] || {
  print -u2 '用法：zsh Scripts/build.sh [check|adhoc|release]'; exit 1
}
[[ "$(uname -m)" == arm64 ]] || { print -u2 '只支持 Apple Silicon 构建。'; exit 1; }
cd "$PROJECT_DIR"
BUILD_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jingxu-build.XXXXXX")
trap 'rm -rf "$BUILD_TEMP"' EXIT
python3 Scripts/release-metadata.py --output "$BUILD_TEMP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Packaging/Info.plist)

KEYCHAIN_OPTIONS=()
IDENTITY_KEYCHAIN=()
SIGN_OPTIONS=(--sign -)
if [[ "$MODE" == release ]]; then
  [[ "${DEVELOPER_ID_APPLICATION:-}" == 'Developer ID Application:'* ]] || { print -u2 '请配置 Developer ID Application 签名身份。'; exit 1; }
  [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && -n "${DEVELOPER_TEAM_ID:-}" ]] || { print -u2 '请配置 NOTARY_KEYCHAIN_PROFILE 与 DEVELOPER_TEAM_ID。'; exit 1; }
  if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then
    KEYCHAIN_OPTIONS=(--keychain "$NOTARY_KEYCHAIN_PATH")
    IDENTITY_KEYCHAIN=("$NOTARY_KEYCHAIN_PATH")
  fi
  security find-identity -v -p codesigning "${IDENTITY_KEYCHAIN[@]}" | grep -F -- "$DEVELOPER_ID_APPLICATION" >/dev/null || { print -u2 '找不到有效签名身份。'; exit 1; }
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
  SIGN_OPTIONS=(--sign "$DEVELOPER_ID_APPLICATION" --timestamp "${KEYCHAIN_OPTIONS[@]}")
fi

if [[ "$MODE" != check ]]; then
  SUFFIX=''
  [[ "$MODE" != adhoc ]] || SUFFIX="-test.${BUILD}"
  OUTPUT_DMG="${PROJECT_DIR}/outputs/JingXu-${VERSION}${SUFFIX}-macOS-arm64.dmg"
  [[ ! -e "$OUTPUT_DMG" && ! -e "${OUTPUT_DMG}.sha256" ]] || { print -u2 '版本产物已存在，请先归档或使用新版本。'; exit 1; }
fi

swift --version
python3 -m unittest discover -s Tests/ReleasePipeline -v
# Pin dependency resolution and architecture in both configurations and all modes.
SWIFT_OPTIONS=(--arch arm64 --disable-automatic-resolution)
swift build -c debug "${SWIFT_OPTIONS[@]}"
swift build -c release "${SWIFT_OPTIONS[@]}"
BINARY_DIR=$(swift build -c release "${SWIFT_OPTIONS[@]}" --show-bin-path)
"${BINARY_DIR}/JingXuChecks"
if [[ "$MODE" == check ]]; then
  print '构建与回归检查通过。'
  exit 0
fi

STAGING="${BUILD_TEMP}/image"
APP_DIR="${STAGING}/镜序.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BINARY_DIR}/JingXuApp" "${APP_DIR}/Contents/MacOS/JingXuApp"
cp Packaging/Info.plist "${APP_DIR}/Contents/Info.plist"
zsh Scripts/build-icon.sh
cp Packaging/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
# Include dependency resource bundles, such as GRDB's privacy manifest.
for bundle in "${BINARY_DIR}"/*.bundle(N); do
  cp -R "$bundle" "${APP_DIR}/Contents/Resources/"
done
if [[ "$MODE" == adhoc ]]; then
  /usr/libexec/PlistBuddy -c 'Add JingXuReleaseChannel string 未公证测试版' "${APP_DIR}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add NSHumanReadableCopyright string 未公证测试版 · 仅供测试' "${APP_DIR}/Contents/Info.plist"
  cp Packaging/TestUpgrade-zh-Hans.txt "${STAGING}/测试版安装说明.txt"
else
  cp Packaging/Upgrade-zh-Hans.txt "${STAGING}/升级说明.txt"
fi
ln -s /Applications "${STAGING}/应用程序"
chmod 755 "${APP_DIR}/Contents/MacOS/JingXuApp"
codesign --force --options runtime "${SIGN_OPTIONS[@]}" --entitlements JingXu.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

notarize() {
  local archive="$1" result="$2"
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "${KEYCHAIN_OPTIONS[@]}" --wait --output-format plist > "$result"
  local outcome=$(/usr/libexec/PlistBuddy -c 'Print status' "$result")
  [[ "$outcome" == Accepted ]] || { print -u2 "公证未通过：${outcome}"; return 1; }
}
if [[ "$MODE" == release ]]; then
  codesign -dv "$APP_DIR" 2>&1 | grep -Fx "TeamIdentifier=${DEVELOPER_TEAM_ID}" >/dev/null
  # ZIP is temporary notary input, never a published asset.
  ditto -c -k --keepParent "$APP_DIR" "${BUILD_TEMP}/notary-upload.zip"
  notarize "${BUILD_TEMP}/notary-upload.zip" "${BUILD_TEMP}/app-notary.plist"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl --assess --type execute --verbose "$APP_DIR"
fi
hdiutil create -volname "镜序 ${VERSION}${SUFFIX}" -srcfolder "$STAGING" -format UDZO "${BUILD_TEMP}/image.dmg"
if [[ "$MODE" == release ]]; then
  codesign "${SIGN_OPTIONS[@]}" "${BUILD_TEMP}/image.dmg"
  notarize "${BUILD_TEMP}/image.dmg" "${BUILD_TEMP}/dmg-notary.plist"
  xcrun stapler staple "${BUILD_TEMP}/image.dmg"
  xcrun stapler validate "${BUILD_TEMP}/image.dmg"
  codesign --verify --strict "${BUILD_TEMP}/image.dmg"
fi
hdiutil verify "${BUILD_TEMP}/image.dmg"
mkdir -p outputs
cp -n "${BUILD_TEMP}/image.dmg" "$OUTPUT_DMG"
cp "${BUILD_TEMP}/RELEASE.md" outputs/RELEASE.md
cd outputs
shasum -a 256 "${OUTPUT_DMG:t}" > "${OUTPUT_DMG:t}.sha256"
print "已生成 ${MODE} 安装包：${OUTPUT_DMG}（build ${BUILD}）"
