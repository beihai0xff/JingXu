#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${PROJECT_DIR}/Packaging/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${PROJECT_DIR}/Packaging/Info.plist")
OUTPUT_DMG="${PROJECT_DIR}/outputs/JingXu-${VERSION}-macOS-arm64.dmg"
[[ ! -e "$OUTPUT_DMG" && ! -e "${OUTPUT_DMG}.sha256" ]] || { print -u2 "版本产物已存在，请使用新版本或先归档旧产物。"; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 "本脚本只构建 Apple Silicon 版本。"; exit 1; }
[[ "${DEVELOPER_ID_APPLICATION:-}" == 'Developer ID Application:'* ]] || { print -u2 "请设置 DEVELOPER_ID_APPLICATION 为钥匙串中的 Developer ID Application 证书名称。"; exit 1; }
[[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && -n "${DEVELOPER_TEAM_ID:-}" ]] || { print -u2 "请配置 NOTARY_KEYCHAIN_PROFILE 与 DEVELOPER_TEAM_ID；凭据仅存钥匙串。"; exit 1; }
# CI uses an isolated keychain; local builds use the normal keychain search list.
IDENTITY_KEYCHAIN=()
KEYCHAIN_OPTIONS=()
if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then
  IDENTITY_KEYCHAIN=("$NOTARY_KEYCHAIN_PATH")
  KEYCHAIN_OPTIONS=(--keychain "$NOTARY_KEYCHAIN_PATH")
fi
/usr/bin/security find-identity -v -p codesigning "${IDENTITY_KEYCHAIN[@]}" | /usr/bin/grep -F -- "$DEVELOPER_ID_APPLICATION" >/dev/null || { print -u2 "找不到有效签名身份。"; exit 1; }
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
PACKAGE_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jingxu-release.XXXXXX")
trap 'rm -rf "${PACKAGE_TEMP}"' EXIT
STAGING="${PACKAGE_TEMP}/image"
APP_DIR="${STAGING}/镜序.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cd "$PROJECT_DIR"
swift build -c release --product JingXuApp --arch arm64
cp .build/arm64-apple-macosx/release/JingXuApp "${APP_DIR}/Contents/MacOS/JingXuApp"
cp Packaging/Info.plist "${APP_DIR}/Contents/Info.plist"
zsh Scripts/build-icon.sh
cp Packaging/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp Packaging/Upgrade-zh-Hans.txt "${STAGING}/升级说明.txt"
ln -s /Applications "${STAGING}/应用程序"
chmod 755 "${APP_DIR}/Contents/MacOS/JingXuApp"
xattr -cr "$APP_DIR"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "${KEYCHAIN_OPTIONS[@]}" --entitlements JingXu.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | /usr/bin/grep -Fx "TeamIdentifier=${DEVELOPER_TEAM_ID}" >/dev/null
# ZIP is only an ephemeral notary upload, never a release asset.
ditto -c -k --keepParent "$APP_DIR" "${PACKAGE_TEMP}/notary-upload.zip"
xcrun notarytool submit "${PACKAGE_TEMP}/notary-upload.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "${KEYCHAIN_OPTIONS[@]}" --wait --output-format plist > "${PACKAGE_TEMP}/app-notary.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print status' "${PACKAGE_TEMP}/app-notary.plist")" == Accepted ]]
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR"
hdiutil create -volname "镜序 ${VERSION}" -srcfolder "$STAGING" -format UDZO "${PACKAGE_TEMP}/release.dmg"
codesign --timestamp --sign "$DEVELOPER_ID_APPLICATION" "${KEYCHAIN_OPTIONS[@]}" "${PACKAGE_TEMP}/release.dmg"
xcrun notarytool submit "${PACKAGE_TEMP}/release.dmg" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "${KEYCHAIN_OPTIONS[@]}" --wait --output-format plist > "${PACKAGE_TEMP}/dmg-notary.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print status' "${PACKAGE_TEMP}/dmg-notary.plist")" == Accepted ]]
xcrun stapler staple "${PACKAGE_TEMP}/release.dmg"
xcrun stapler validate "${PACKAGE_TEMP}/release.dmg"
codesign --verify --strict "${PACKAGE_TEMP}/release.dmg"
hdiutil verify "${PACKAGE_TEMP}/release.dmg"
mkdir -p "${PROJECT_DIR}/outputs"
cp -n "${PACKAGE_TEMP}/release.dmg" "$OUTPUT_DMG"
cd "${PROJECT_DIR}/outputs"
shasum -a 256 "${OUTPUT_DMG:t}" > "${OUTPUT_DMG:t}.sha256"
print "已生成正式公证 DMG：${OUTPUT_DMG}（build ${BUILD}）"
