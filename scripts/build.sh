#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="$PWD/build"
APP="$BUILD_DIR/MenuPlay.app"
MODULE_CACHE="$BUILD_DIR/module-cache"
APP_VERSION="1.1.1"
APP_BUILD="1"

rm -rf "$APP" "$MODULE_CACHE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

xcrun --sdk macosx swiftc -O \
    -o "$APP/Contents/MacOS/MenuPlay" \
    -framework AppKit \
    -framework Security \
    -framework SwiftUI \
    MenuPlay/MenuPlay/MenuPlayApp.swift \
    MenuPlay/MenuPlay/KeychainStore.swift \
    MenuPlay/MenuPlay/SpotifyService.swift \
    MenuPlay/MenuPlay/SpotifyAPI.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MenuPlay</string>
    <key>CFBundleIdentifier</key>
    <string>com.menuplay.app</string>
    <key>CFBundleName</key>
    <string>MenuPlay</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>MenuPlay needs access to Spotify to display the current track.</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.menuplay.callback</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>menuplay</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cp MenuPlay/MenuPlay/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Built: $APP"
