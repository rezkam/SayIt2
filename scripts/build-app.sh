#!/bin/bash
# Builds and signs "build/SayIt2.app". With --notarize, also has Apple notarize it.
#
#   bash scripts/build-app.sh               build and sign
#   bash scripts/build-app.sh --notarize    build, sign, notarize, and staple the ticket
#
# Version: the VERSION file. Build number: the number of commits.
#
# Environment (nothing identifying is stored in the repository):
#   SAYIT2_SIGNING_IDENTITY  Developer ID Application certificate; falls back to
#                            SPEAKFLOW_SIGNING_IDENTITY, then the first code signing identity.
#   SAYIT2_NOTARY_PROFILE    notarytool keychain profile; falls back to SPEAKFLOW_NOTARY_PROFILE.
#   SAYIT2_BUNDLE_ID         bundle identifier; default local.sayit2.
#   SAYIT2_REPO              GitHub owner/name for the update feed; default: the origin remote.
# The update signing key lives in the login Keychain under the Sparkle account "sayit2".
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < VERSION)"
build="$(git rev-list --count HEAD)"
sparkle=".build/artifacts/sparkle/Sparkle"

xcrun swift build -c release
binary="$(xcrun swift build -c release --show-bin-path)/SayIt2"

# Updates are enabled when the GitHub repository is known.
repo="${SAYIT2_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)}"
update_keys=""
if [[ -n "$repo" ]]; then
    public_key="$("$sparkle/bin/generate_keys" -p --account sayit2)"
    update_keys="
    <key>SUFeedURL</key><string>https://github.com/$repo/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>$public_key</string>
    <key>SURequireSignedFeed</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUEnableSystemProfiling</key><false/>"
fi

app="build/SayIt2.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp -f "$binary" "$app/Contents/MacOS/SayIt2"
cp -f Resources/Fonts/Vazirmatn.ttf Resources/Fonts/Vazirmatn-OFL.txt "$app/Contents/Resources/"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
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
    <key>NSMicrophoneUsageDescription</key><string>SayIt2 listens while you hold or double-tap Right Option, to type what you say.</string>$update_keys
</dict>
</plist>
PLIST

identity="${SAYIT2_SIGNING_IDENTITY:-${SPEAKFLOW_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}}"
if [[ -n "$identity" ]]; then
    # Inside out: Sparkle's helpers, Sparkle, then the app. Hardened runtime and a secure
    # timestamp are what Apple's notary service requires.
    sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
    framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$framework/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc"
    sign "$framework/Autoupdate"
    sign "$framework/Updater.app"
    sign "$app/Contents/Frameworks/Sparkle.framework"
    sign --entitlements scripts/SayIt2.entitlements "$app"
else
    codesign --force --deep --sign - "$app"
fi
codesign --verify --deep --strict "$app"

if [[ "${1:-}" == "--notarize" ]]; then
    profile="${SAYIT2_NOTARY_PROFILE:-${SPEAKFLOW_NOTARY_PROFILE:?set SAYIT2_NOTARY_PROFILE to a notarytool keychain profile}}"
    archive="$(mktemp -d)/SayIt2.zip"
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

echo "$app: version $version (build $build)${repo:+, updates from $repo}"
