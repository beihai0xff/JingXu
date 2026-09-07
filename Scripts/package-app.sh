#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PACKAGE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/jingxu-package.XXXXXX")"
APP_DIR="${PACKAGE_TEMP}/镜序.app"
CONTENTS_DIR="${APP_DIR}/Contents"
OUTPUT_ZIP="${PROJECT_DIR}/outputs/JingXu-macOS-MVP.zip"
trap 'rm -rf "${PACKAGE_TEMP}"' EXIT

cd "${PROJECT_DIR}"
swift build -c release --product JingXuApp

mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
cp "${PROJECT_DIR}/.build/release/JingXuApp" "${CONTENTS_DIR}/MacOS/JingXuApp"
cp "${PROJECT_DIR}/Packaging/Info.plist" "${CONTENTS_DIR}/Info.plist"
chmod 755 "${CONTENTS_DIR}/MacOS/JingXuApp"
xattr -cr "${APP_DIR}"

codesign --force --deep --sign - --entitlements "${PROJECT_DIR}/JingXu.entitlements" "${APP_DIR}"
mkdir -p "${PROJECT_DIR}/outputs"
if [[ -e "${OUTPUT_ZIP}" ]]; then
    rm -f "${OUTPUT_ZIP}"
fi
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${OUTPUT_ZIP}"
codesign --verify --deep --strict "${APP_DIR}"

print "已生成：${OUTPUT_ZIP}"
