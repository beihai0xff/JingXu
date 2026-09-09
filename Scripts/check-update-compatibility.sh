#!/bin/bash
# First gate only: a successful load is NOT an end-to-end updater acceptance test.
# No security exceptions, key creation, network requests or real catalog access.
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:?Usage: bash Scripts/check-update-compatibility.sh /path/to/Sparkle-2.9.6.tar.xz}"
EXPECTED=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Sparkle distribution digest mismatch'; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'This probe targets Apple Silicon'; exit 1; }
PROBE_WORK="$(mktemp -d /tmp/jingxu-update-compatibility.XXXXXX)"
echo "Evidence directory: $PROBE_WORK"
tar -xf "$ARCHIVE" -C "$PROBE_WORK" ./Sparkle.framework
ulimit -c 0
for VARIANT in baseline sparkle; do
    PROBE_APP="$PROBE_WORK/$VARIANT.app"
    mkdir -p "$PROBE_APP/Contents/MacOS"
    cp "$PROBE_ROOT/Tests/UpdateCompatibility/Info.plist" "$PROBE_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier app.jingxu.updatecompatibility.$VARIANT" "$PROBE_APP/Contents/Info.plist"
    COMPILER=(swiftc -O -target arm64-apple-macosx14.0)
    if [[ "$VARIANT" == sparkle ]]; then
        mkdir -p "$PROBE_APP/Contents/Frameworks"
        ditto --norsrc --noextattr "$PROBE_WORK/Sparkle.framework" "$PROBE_APP/Contents/Frameworks/Sparkle.framework"
        # Match the host's ad-hoc identity, without changing the framework's runtime options.
        codesign --force --options runtime --sign - "$PROBE_APP/Contents/Frameworks/Sparkle.framework"
        COMPILER+=(-D SPARKLE_PROBE -F "$PROBE_APP/Contents/Frameworks" -framework Sparkle
               -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
    fi
    "${COMPILER[@]}" \
        "$PROBE_ROOT/Tests/UpdateCompatibility/Probe.swift" -o "$PROBE_APP/Contents/MacOS/UpdateProbe"
    codesign --force --options runtime --sign - --entitlements "$PROBE_ROOT/JingXu.entitlements" "$PROBE_APP"
    codesign --verify --deep --strict "$PROBE_APP"
    codesign -dvvv --entitlements :- "$PROBE_APP" > "$PROBE_WORK/$VARIANT-signature.txt" 2>&1
    otool -L "$PROBE_APP/Contents/MacOS/UpdateProbe" > "$PROBE_WORK/$VARIANT-libraries.txt"
    set +e
    "$PROBE_APP/Contents/MacOS/UpdateProbe" > "$PROBE_WORK/$VARIANT-output.txt" 2>&1
    RESULT=$?
    set -e
    echo "$VARIANT exit status: $RESULT"
    cat "$PROBE_WORK/$VARIANT-output.txt"
    if [[ "$VARIANT" == baseline ]]; then
        [[ "$RESULT" == 0 ]] && grep -q BASELINE_LOADED "$PROBE_WORK/$VARIANT-output.txt" || {
            echo 'INCONCLUSIVE: baseline failed; no conclusions about Sparkle'; exit 1;
        }
    elif [[ "$RESULT" != 0 ]]; then
        echo 'BLOCKED: Sparkle loading failed. Do not proceed with application integration.'
        exit 78
    else
        grep -q SPARKLE_LOADED "$PROBE_WORK/$VARIANT-output.txt"
        echo 'LOAD GATE ONLY passed; XPC, download, installation and relaunch are still unverified.'
    fi
done
