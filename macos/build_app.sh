#!/bin/bash
# Builds "Field Command.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FieldCommand"
# The title screen shows this same string (Defs.swift), so the bundle cannot drift out of step.
VERSION="$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/FieldCommand/Defs.swift)"
VERSION="${VERSION:-1.0.0}"
APP="build/Field Command.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FieldCommand"

if [ ! -f build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Field Command</string>
    <key>CFBundleDisplayName</key><string>Field Command</string>
    <key>CFBundleIdentifier</key><string>com.fieldcommand.rts</string>
    <key>CFBundleExecutable</key><string>FieldCommand</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.strategy-games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>Field Command uses your local network to host and join multiplayer games.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP ($VERSION)"
