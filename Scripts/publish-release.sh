#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"
[[ -z "$(git status --porcelain)" ]] || { print -u2 "必须从干净的已合入提交发布。"; exit 1; }
git fetch origin main
COMMIT=$(git rev-parse HEAD)
[[ "$COMMIT" == "$(git rev-parse origin/main)" ]] || { print -u2 "当前提交不是 origin/main。"; exit 1; }
[[ "${RELEASE_ACCEPTANCE_COMMIT:-}" == "$COMMIT" ]] || { print -u2 "交互、覆盖升级及 Gatekeeper 验收通过后，将 RELEASE_ACCEPTANCE_COMMIT 设置为该提交完整 SHA。"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)
TAG="v${VERSION}"
REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/${TAG}")
[[ -z "$REMOTE_TAG" ]] || { print -u2 "远端版本标签已存在，不覆盖。"; exit 1; }
METADATA_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jingxu-release-metadata.XXXXXX")
trap 'rm -rf "$METADATA_TEMP"' EXIT
python3 Scripts/ci-release-metadata.py --ref "refs/tags/${TAG}" --output "$METADATA_TEMP"
git tag -a "$TAG" "$COMMIT" -m "JingXu ${VERSION}"
git push origin "refs/tags/${TAG}"
print "已推送 ${TAG}。GitHub Actions 将统一执行构建、签名、公证、Release 和 Cask 更新。"
print "查看结果：https://github.com/beihai0xff/JingXu/actions/workflows/release.yml"
