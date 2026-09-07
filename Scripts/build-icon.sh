#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ICON_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jingxu-icon.XXXXXX")
trap 'rm -rf "${ICON_TEMP}"' EXIT
mkdir "${ICON_TEMP}/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "${PROJECT_DIR}/Packaging/AppIcon.png" --out "${ICON_TEMP}/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "${PROJECT_DIR}/Packaging/AppIcon.png" --out "${ICON_TEMP}/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICON_TEMP}/AppIcon.iconset" -o "${PROJECT_DIR}/Packaging/AppIcon.icns"
