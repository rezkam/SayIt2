#!/bin/bash
# Builds and signs "build/SayIt2.app". With --notarize, also has Apple notarize it.
#
#   bash scripts/build-app.sh               build and sign
#   bash scripts/build-app.sh --notarize    build, sign, notarize, and staple the ticket
#
# The version comes from the VERSION file; the build number is the number of commits.
#
# Signing identity (a Developer ID Application certificate): SAYIT2_SIGNING_IDENTITY, else
# SPEAKFLOW_SIGNING_IDENTITY, else the first code signing identity in the keychain, else an
# ad-hoc signature. A stable identity keeps the Accessibility and Microphone grants across builds.
# Notarizing needs a notarytool keychain profile: SAYIT2_NOTARY_PROFILE, else SPEAKFLOW_NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < VERSION)"
build="$(git rev-list --count HEAD)"

xcrun swift build -c release
binary="$(xcrun swift build -c release --show-bin-path)/SayIt2"

app="build/SayIt2.app"
mkdir -p "$app/Contents/MacOS"
cp -f "$binary" "$app/Contents/MacOS/SayIt2"
mkdir -p "$app/Contents/Resources"
cp -f Resources/Fonts/Vazirmatn.ttf Resources/Fonts/Vazirmatn-OFL.txt "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SayIt2</string>
    <key>CFBundleDisplayName</key><string>SayIt2</string>
    <key>CFBundleIdentifier</key><string>${SAYIT2_BUNDLE_ID:-local.sayit2}</string>
    <key>CFBundleExecutable</key><string>SayIt2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>SayIt2 listens while you hold or double-tap Right Option, to type what you say.</string>
</dict>
</plist>
PLIST

identity="${SAYIT2_SIGNING_IDENTITY:-${SPEAKFLOW_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}}"
if [[ -n "$identity" ]]; then
    # Hardened runtime and a secure timestamp are what Apple's notary service requires.
    codesign --force --options runtime --timestamp --entitlements scripts/SayIt2.entitlements --sign "$identity" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

if [[ "${1:-}" == "--notarize" ]]; then
    profile="${SAYIT2_NOTARY_PROFILE:-${SPEAKFLOW_NOTARY_PROFILE:?set SAYIT2_NOTARY_PROFILE to a notarytool keychain profile}}"
    archive="$(mktemp -d)/SayIt2.zip"
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

echo "$app: version $version (build $build)"
