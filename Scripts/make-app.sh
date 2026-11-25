#!/bin/bash
# Builds "API Playground.app" into ./build from the Swift package.
# Usage: Scripts/make-app.sh [debug|release] [test]
#
# With "test", builds "API Playground Test.app" instead: a separate app with its own
# identifier, settings and data folder, so trying things out never touches the real
# app's data or a copy of it that is already running.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

NAME="API Playground"
BUNDLE_ID="com.apiplayground.app"
if [ "${2:-}" = "test" ]; then
    NAME="API Playground Test"
    BUNDLE_ID="com.apiplayground.app.test"
elif pgrep -x APIPlayground >/dev/null && pgrep -fl APIPlayground | grep -q "build/API Playground.app/"; then
    echo "API Playground is running. Quit it first, so it is not replaced while in use." >&2
    exit 1
fi

# SwiftUI needs the full Xcode toolchain, not just the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG" --product APIPlayground
BIN="$(swift build -c "$CONFIG" --show-bin-path)/APIPlayground"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/APIPlayground"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Postman export</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature, for running locally. Distribution needs Developer ID signing and notarisation.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
