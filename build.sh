#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/MenuPlay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -o "$APP/Contents/MacOS/MenuPlay" \
    -framework AppKit \
    -framework Security \
    -framework SwiftUI \
    MenuPlay/MenuPlay/MenuPlayApp.swift \
    MenuPlay/MenuPlay/KeychainStore.swift \
    MenuPlay/MenuPlay/SpotifyService.swift \
    MenuPlay/MenuPlay/SpotifyAPI.swift

cat > "$APP/Contents/Info.plist" << 'PLIST'
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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
