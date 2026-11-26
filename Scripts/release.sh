#!/bin/bash
# Makes the download: a signed, notarised disk image of API Playground.
# Usage: Scripts/release.sh
#
# Steps: run the tests, build for Apple silicon and Intel, sign with Developer ID,
# notarise and staple the app, pack it into a disk image, sign, notarise and staple
# that, and (when release.conf names a feed) add the release to the update feed.
#
# Set SKIP_NOTARISE=1 to stop short of sending anything to Apple.
# Everything lands in build/release.
set -euo pipefail

cd "$(dirname "$0")/.."
FROM_ENV="${SIGN_IDENTITY:-}"
source Scripts/release.conf
SIGN_IDENTITY="${FROM_ENV:-$SIGN_IDENTITY}"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

NAME="API Playground"
APP="build/$NAME.app"
OUT="build/release"
DMG="$OUT/API-Playground-$VERSION.dmg"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application certificate was found in the Keychain." >&2
    exit 1
fi

NOTARISE=1
if [ "${SKIP_NOTARISE:-}" = "1" ]; then
    NOTARISE=0
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notarisation is not set up yet. Run this once, then run the release again:" >&2
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    echo "Or set SKIP_NOTARISE=1 to make a signed disk image that is not notarised." >&2
    exit 1
fi

notarise() {
    # Sends a file to Apple and waits for the answer. Prints Apple's log when it says no.
    local file="$1" output id
    output="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
    echo "$output" | tail -4
    if ! echo "$output" | grep -q "status: Accepted"; then
        id="$(echo "$output" | sed -n 's/^ *id: //p' | head -1)"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        echo "Apple did not accept $file." >&2
        exit 1
    fi
}

echo "== Tests"
swift test 2>&1 | tail -3

echo "== Build and sign ($IDENTITY)"
UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" Scripts/make-app.sh release

rm -rf "$OUT/stage"
mkdir -p "$OUT/stage"

if [ "$NOTARISE" = "1" ]; then
    echo "== Notarise the app"
    ditto -c -k --keepParent "$APP" "$OUT/stage/app.zip"
    notarise "$OUT/stage/app.zip"
    rm "$OUT/stage/app.zip"
    xcrun stapler staple "$APP"
fi

echo "== Disk image"
ditto "$APP" "$OUT/stage/$NAME.app"
ln -s /Applications "$OUT/stage/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$OUT/stage"
codesign --force --sign "$IDENTITY" --timestamp --identifier com.apiplayground.app.dmg "$DMG"

if [ "$NOTARISE" = "1" ]; then
    echo "== Notarise the disk image"
    notarise "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -2
fi

if [ -n "$FEED_URL" ]; then
    echo "== Update feed"
    # Signs each disk image in the folder with the update key and writes appcast.xml beside them.
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account "$SPARKLE_KEY_ACCOUNT" \
        --download-url-prefix "${FEED_URL%/*}/" "$OUT"
    echo "Upload $DMG and $OUT/appcast.xml to ${FEED_URL%/*}/"
else
    echo "No update feed is set in Scripts/release.conf, so this build does not check for updates."
fi

echo "Made $DMG"
