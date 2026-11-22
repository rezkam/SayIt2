#!/bin/bash
# Release candidates and releases.
#
#   bash scripts/release.sh rc         build, sign, notarize, install to /Applications, open
#   bash scripts/release.sh publish    publish the tested commit as release v<VERSION>
#
# Flow: commit, `rc`, try the installed app, then `publish` from the same commit after
# bumping nothing. `publish` refuses a dirty tree, a commit that is not on origin/main, or a
# version that is already released. It uploads a notarized DMG and a signed appcast.xml,
# which installed copies check once a day (see scripts/build-app.sh for the environment).
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
version="$(tr -d '[:space:]' < VERSION)"
sparkle=".build/artifacts/sparkle/Sparkle"
fail() { echo "error: $*" >&2; exit 1; }

[[ "$mode" == rc || "$mode" == publish ]] || fail "usage: release.sh rc|publish"
[[ -z "$(git status --porcelain)" ]] || fail "commit your changes first"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3"

rc="build/rc"
app="$rc/SayIt2.app"
dsym="$rc/SayIt2.dSYM"

if [[ "$mode" == rc ]]; then
    bash scripts/build-app.sh --notarize
    [[ "$(codesign -dv "build/SayIt2.app" 2>&1)" == *"(runtime)"* ]] || fail "app is not signed for release"
    rm -rf "$rc" && mkdir -p "$rc"
    ditto build/SayIt2.app "$app"
    ditto build/SayIt2.dSYM "$dsym"
    git rev-parse HEAD > "$rc/commit"
    pkill -x SayIt2 || true
    # Replace, not merge: a file left over from an earlier build would break the signature.
    rm -rf /Applications/SayIt2.app
    ditto "$app" /Applications/SayIt2.app
    open /Applications/SayIt2.app
    echo "Installed release candidate $version ($(git rev-parse --short HEAD)). Try it, then: release.sh publish"
    exit 0
fi

git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push this commit to origin/main first"
! gh release view "v$version" >/dev/null 2>&1 || fail "v$version is already released; bump VERSION"
[[ -d "$app" && -d "$dsym" && -f "$rc/commit" ]] || fail "run release.sh rc for this commit first"
[[ "$(cat "$rc/commit")" == "$(git rev-parse HEAD)" ]] || fail "release candidate is for a different commit; run release.sh rc"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)" == "$version" ]] || fail "release candidate version does not match VERSION; run release.sh rc"
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || true)" == "$(git rev-list --count HEAD)" ]] || fail "release candidate build number does not match HEAD; run release.sh rc"
[[ "$(codesign -dv "$app" 2>&1)" == *"(runtime)"* ]] || fail "app is not signed for release"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose "$app"

# Disk image with the app and a link to /Applications, signed and notarized.
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
identity="${SAYIT2_SIGNING_IDENTITY:?set SAYIT2_SIGNING_IDENTITY}"
profile="${SAYIT2_NOTARY_PROFILE:?set SAYIT2_NOTARY_PROFILE}"
out="build/release-$version"
rm -rf "$out" && mkdir -p "$out/stage"
ditto "$app" "$out/stage/SayIt2.app"
ln -s /Applications "$out/stage/Applications"
dmg="$out/SayIt2-$version.dmg"
hdiutil create -quiet -volname "SayIt2 $version" -srcfolder "$out/stage" -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"

# Debug symbols to Sentry, so crash reports from this release show function names.
dsn="$(/usr/libexec/PlistBuddy -c "Print :SentryDSN" "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$dsn" ]]; then
    command -v sentry >/dev/null || fail "install and sign in to the sentry tool to upload debug symbols"
    SENTRY_DSN="$dsn" sentry debug-files upload "$dsym" --type dsym
fi

# Update feed: one item for this release, with the DMG's signature, then the feed itself signed.
signature="$("$sparkle/bin/sign_update" --account sayit2 -p "$dmg")"
url="https://github.com/$repo/releases/download/v$version/SayIt2-$version.dmg"
notes="$(git log -1 --format=%s)"
cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SayIt2</title>
    <item>
      <title>SayIt2 $version</title>
      <sparkle:version>$(git rev-list --count HEAD)</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[$notes]]></description>
      <enclosure url="$url" length="$(wc -c < "$dmg" | tr -d " ")" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
"$sparkle/bin/sign_update" --account sayit2 "$out/appcast.xml"
"$sparkle/bin/sign_update" --account sayit2 --verify "$out/appcast.xml"

gh release create "v$version" "$dmg" "$out/appcast.xml" --target "$(git rev-parse HEAD)" \
    --title "SayIt2 $version" --notes "$notes"

# Check what was published: the downloaded DMG must match and pass Gatekeeper.
check="$(mktemp -d)"
gh release download "v$version" --pattern "*.dmg" --dir "$check"
cmp "$dmg" "$check/SayIt2-$version.dmg"
spctl --assess --type open --context context:primary-signature "$check/SayIt2-$version.dmg"
rm -rf "$check"
echo "Published SayIt2 $version: https://github.com/$repo/releases/tag/v$version"
