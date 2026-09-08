#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"
command -v gh >/dev/null || { print -u2 "需要 GitHub CLI（gh）及仓库发布权限。"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "必须从干净的已合入提交发布。"; exit 1; }
git fetch origin main
COMMIT=$(git rev-parse HEAD)
[[ "$COMMIT" == "$(git rev-parse origin/main)" ]] || { print -u2 "当前提交不是 origin/main。"; exit 1; }
[[ "${RELEASE_ACCEPTANCE_COMMIT:-}" == "$COMMIT" ]] || { print -u2 "交互、覆盖升级及 Gatekeeper 验收通过后，将 RELEASE_ACCEPTANCE_COMMIT 设置为该提交完整 SHA。"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)
TAG="v${VERSION}"
[[ -z "$(git ls-remote --tags origin "refs/tags/${TAG}")" ]] || { print -u2 "远端版本标签已存在，不覆盖。"; exit 1; }
if gh release view "$TAG" --repo beihai0xff/JingXu >/dev/null 2>&1; then
    print -u2 "Release 已存在，不覆盖。"; exit 1
fi
swift build
swift run JingXuChecks
Scripts/package-app.sh
DMG="outputs/JingXu-${VERSION}-macOS-arm64.dmg"
(cd outputs && shasum -a 256 -c "${DMG:t}.sha256")
git tag -a "$TAG" "$COMMIT" -m "JingXu ${VERSION}"
git push origin "refs/tags/${TAG}"
gh release create "$TAG" "$DMG" "${DMG}.sha256" --repo beihai0xff/JingXu --verify-tag --draft --title "镜序 ${VERSION}" --notes-file Packaging/ReleaseNotes.md
print "已创建发布草稿。确认下载产物无误后，使用 gh release edit ${TAG} --repo beihai0xff/JingXu --draft=false 发布。"
