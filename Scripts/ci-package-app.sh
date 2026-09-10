#!/bin/bash
# GitHub-hosted runner only: keep the certificate and notary credentials in one
# temporary keychain. Never change the user's default keychain or search list.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'This script requires a GitHub Actions runner.' >&2; exit 1; }
: "${RUNNER_TEMP:?Missing RUNNER_TEMP}"
: "${DEVELOPER_ID_APPLICATION:?Missing DEVELOPER_ID_APPLICATION}"
: "${DEVELOPER_TEAM_ID:?Missing DEVELOPER_TEAM_ID}"
: "${APPLE_ID:?Missing APPLE_ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Missing APPLE_APP_SPECIFIC_PASSWORD}"
: "${DEVELOPER_ID_P12_BASE64:?Missing DEVELOPER_ID_P12_BASE64}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing DEVELOPER_ID_P12_PASSWORD}"

umask 077
SIGNING_DIRECTORY=$(mktemp -d "${RUNNER_TEMP}/jingxu-signing.XXXXXX")
export NOTARY_KEYCHAIN_PATH="${SIGNING_DIRECTORY}/signing.keychain-db"
export NOTARY_KEYCHAIN_PROFILE=jingxu-notary
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -f "$NOTARY_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$NOTARY_KEYCHAIN_PATH" || result=1
  fi
  rm -rf "$SIGNING_DIRECTORY"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "${SIGNING_DIRECTORY}/certificate.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$NOTARY_KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN_PATH"
security import "${SIGNING_DIRECTORY}/certificate.p12" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -k "$NOTARY_KEYCHAIN_PATH" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN_PATH" >/dev/null
rm "${SIGNING_DIRECTORY}/certificate.p12"
xcrun notarytool store-credentials "$NOTARY_KEYCHAIN_PROFILE" \
  --keychain "$NOTARY_KEYCHAIN_PATH" --apple-id "$APPLE_ID" \
  --team-id "$DEVELOPER_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD APPLE_APP_SPECIFIC_PASSWORD KEYCHAIN_PASSWORD
zsh "$(dirname "$0")/build.sh" release
