#!/bin/bash
# Builds "build/SayIt 2.app" and signs it.
#
# Signing with a stable identity keeps the Accessibility and Microphone grants across
# rebuilds. Set SAYIT2_SIGNING_IDENTITY to choose one; otherwise the first code signing
# identity in the keychain is used, or an ad-hoc signature if there is none.
set -euo pipefail
cd "$(dirname "$0")/.."

xcrun swift build -c release
binary="$(xcrun swift build -c release --show-bin-path)/SayIt2"

app="build/SayIt 2.app"
mkdir -p "$app/Contents/MacOS"
cp -f "$binary" "$app/Contents/MacOS/SayIt2"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SayIt 2</string>
    <key>CFBundleDisplayName</key><string>SayIt 2</string>
    <key>CFBundleIdentifier</key><string>${SAYIT2_BUNDLE_ID:-local.sayit2}</string>
    <key>CFBundleExecutable</key><string>SayIt2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>SayIt 2 listens while you hold or double-tap Right Option, to type what you say.</string>
</dict>
</plist>
PLIST

identity="${SAYIT2_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}"
codesign --force --sign "${identity:--}" "$app"
echo "$app"
