#!/bin/bash
# Builds "API Playground.app" into ./build from the Swift package.
# Usage: Scripts/make-app.sh [debug|release] [test]
#
# With "test", builds "API Playground Test.app" instead: a separate app with its own
# identifier, settings and data folder, so trying things out never touches the real
# app's data or a copy of it that is already running.
#
# Set in the environment:
#   SIGN_IDENTITY=…    sign with this certificate and the hardened runtime, ready for
#                      notarisation. Without it the app is signed for this Mac only.
set -euo pipefail

cd "$(dirname "$0")/.."
# Taken before release.conf is read, which has a setting of the same name for release.sh.
IDENTITY="${SIGN_IDENTITY:-}"
source Scripts/release.conf
CONFIG="${1:-release}"

NAME="API Playground"
BUNDLE_ID="com.apiplayground.app"
FEED="$FEED_URL"
if [ "${2:-}" = "test" ]; then
    NAME="API Playground Test"
    BUNDLE_ID="com.apiplayground.app.test"
    # The test copy never updates itself.
    FEED=""
elif pgrep -x APIPlayground >/dev/null && pgrep -fl APIPlayground | grep -q "build/API Playground.app/"; then
    echo "API Playground is running. Quit it first, so it is not replaced while in use." >&2
    exit 1
fi

# SwiftUI needs the full Xcode toolchain, not just the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# The app is for Apple silicon only. It is not built for Intel Macs.
ARCHS=(--arch arm64)
swift build -c "$CONFIG" --product APIPlayground ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/APIPlayground"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/APIPlayground"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The description of the app's Shortcuts actions, which Shortcuts reads from the bundle.
# Xcode makes this as a build step; here it is made from the same compiler output.
CONFIG_DIR="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
SOURCES_LIST="$(find .build/out/Intermediates.noindex -path "*/$CONFIG_DIR/APIPlayground-p.build/Objects-normal/*/APIPlayground.SwiftFileList" 2>/dev/null | head -1)"
if [ -z "$SOURCES_LIST" ]; then
    echo "Could not find the build's file list, so the Shortcuts actions cannot be described." >&2
    exit 1
fi
OBJECTS="$(dirname "$SOURCES_LIST")"
INTENTS_WORK="$(mktemp -d)"
ls "$PWD/$OBJECTS"/*.swiftconstvalues > "$INTENTS_WORK/constvalues.list"
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name APIPlayground \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 \
    --target-triple "$(basename "$OBJECTS")-apple-macos14.0" \
    --source-file-list "$SOURCES_LIST" \
    --swift-const-vals-list "$INTENTS_WORK/constvalues.list" \
    --force > "$INTENTS_WORK/log.txt" 2>&1 || { cat "$INTENTS_WORK/log.txt" >&2; exit 1; }
rm -rf "$INTENTS_WORK"
if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    echo "The Shortcuts actions were not described: Metadata.appintents is missing." >&2
    exit 1
fi

# The licences of the open-source software inside the app, which ask to be passed on with it.
{
    echo "API Playground includes the following open-source software."
    for entry in "Sparkle:.build/artifacts/sparkle/Sparkle/LICENSE" "libgit2:.build/checkouts/swift-libgit2/Sources/Clibgit2/COPYING"; do
        printf '\n\n==== %s ====\n\n' "${entry%%:*}"
        cat "${entry#*:}"
    done
} > "$APP/Contents/Resources/Acknowledgements.txt"

# Sparkle, which installs updates. The app looks for it in its Frameworks folder.
ditto --arch arm64 ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
EXE="$APP/Contents/MacOS/APIPlayground"
if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null
fi
# The build leaves search paths that point into this Mac's build folder and Xcode. Take them out.
otool -l "$EXE" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep -E "^(/Users|/Applications|$PWD)" | while read -r path; do
    install_name_tool -delete_rpath "$path" "$EXE" 2>/dev/null || true
done

UPDATES=""
if [ -n "$FEED" ]; then
    UPDATES="    <key>SUFeedURL</key>
    <string>$FEED</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>APSupportFolderName</key>
    <string>$NAME</string>
    <key>CFBundleExecutable</key>
    <string>APIPlayground</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
$UPDATES
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>API client export</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
                <string>public.yaml</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -n "$IDENTITY" ]; then
    # Developer ID, with the hardened runtime and a timestamp: what notarisation asks for.
    # Signed from the inside out, the way Sparkle's own instructions give it.
    SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    "${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    "${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
    "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
    "${SIGN[@]}" "$SPARKLE"
    "${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"
    codesign --verify --deep --strict "$APP"
else
    # Ad-hoc signature, for running on this Mac only.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi

echo "Built $APP"
