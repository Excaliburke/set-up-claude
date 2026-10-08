#!/bin/bash
#
# Builds "Set Up Claude.app": a small Mac app that runs claude-setup.sh and
# shows its progress in one window, so nobody needs Terminal.
#
#   bash app/build-app.sh
#
# The app lands in dist/, with dist/Set-Up-Claude.zip next to it. The version
# comes from the VERSION file. Building needs Apple's Command Line Tools
# (xcode-select --install). Run it again after changing claude-setup.sh: the
# app carries its own copy. To publish a version, use release.sh, which runs
# this with signing and notarization turned on.
#
# Without an Apple Developer ID the app is signed "ad hoc", and macOS asks each
# person to approve it once. To sign and notarize it so it opens without that,
# set these first:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="profile-name"   # made with: xcrun notarytool store-credentials

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DIST="$ROOT/dist"
APP_NAME="Set Up Claude"
APP="$DIST/$APP_NAME.app"
# No spaces: GitHub renames release files that have them.
ZIP="$DIST/Set-Up-Claude.zip"
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/set-up-claude-build.XXXXXX")

mkdir -p "$DIST"
# Move an earlier build aside rather than deleting it.
[ -e "$APP" ] && mv "$APP" "$BUILD/previous.app"
[ -e "$ZIP" ] && mv "$ZIP" "$BUILD/previous.zip"

echo "Building version $VERSION for Apple silicon and Intel (macOS 13 or newer)…"
for arch in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O \
    -target "$arch-apple-macos13.0" \
    -o "$BUILD/SetUpClaude-$arch" "$HERE/SetUpClaude.swift"
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/SetUpClaude" "$BUILD/SetUpClaude-arm64" "$BUILD/SetUpClaude-x86_64"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp "$ROOT/claude-setup.sh" "$APP/Contents/Resources/claude-setup.sh"

echo "Drawing the icon…"
swiftc -O -o "$BUILD/make-icon" "$HERE/make-icon.swift"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${DEVELOPER_ID:-}" ]; then
  # A keychain can hold several copies of one certificate, and codesign refuses
  # a name that matches more than one, so sign with the first copy's fingerprint.
  case $DEVELOPER_ID in
    *[!0-9A-Fa-f]*)
      SIGN_AS=$(security find-identity -v -p codesigning | awk -v name="\"$DEVELOPER_ID\"" 'index($0, name) { print $2; exit }')
      if [ -z "$SIGN_AS" ]; then
        echo "No signing certificate named \"$DEVELOPER_ID\" in the keychain."
        exit 1
      fi ;;
    *) SIGN_AS=$DEVELOPER_ID ;;
  esac
  echo "Signing with $DEVELOPER_ID…"
  codesign --force --options runtime --timestamp --sign "$SIGN_AS" "$APP"
else
  echo "Signing ad hoc (no DEVELOPER_ID set)…"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Sending to Apple for notarization (usually a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  mv "$ZIP" "$BUILD/before-stapling.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo
echo "Built:  $APP"
echo "Share:  $ZIP"
if [ -z "${DEVELOPER_ID:-}" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
  echo
  echo "Note: this build isn't notarized, so macOS will block it on other Macs until"
  echo "each person approves it. Set DEVELOPER_ID and NOTARY_PROFILE before sharing."
fi
