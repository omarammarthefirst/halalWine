#!/bin/bash
# Builds dist/halalWine.app and dist/halalWine-<version>.dmg on macOS.
#
# Optional signing / notarization (needed so non-technical users can open the
# app without Gatekeeper warnings):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID=you@example.com APPLE_TEAM_ID=TEAMID APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
# Without them the app is ad-hoc signed (fine for testing on your own Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD_NUMBER:-1}"
ARCH="${ARCH:-arm64}"
APP="dist/halalWine.app"

echo "▶ Building halalWine $VERSION ($ARCH)"
swift build -c release --arch "$ARCH" --product HalalWine
swift build -c release --arch "$ARCH" --product halalwine
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HalalWine" "$APP/Contents/MacOS/HalalWine"
cp "$BIN/halalwine" "$APP/Contents/MacOS/halalwine"
# SwiftPM resource bundles (translations, rules.json).
for bundle in "$BIN"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp -R Packaging/en.lproj Packaging/ar.lproj "$APP/Contents/Resources/"

echo "▶ Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▶ Signing"
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/halalwine"
  codesign --force --options runtime --timestamp --entitlements Packaging/halalWine.entitlements \
    --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP"

echo "▶ Disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/halalWine-$VERSION.dmg"
hdiutil create -volname "halalWine" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ -n "${DEVELOPER_ID:-}" ]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"; fi

if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  echo "▶ Notarizing"
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
fi

echo "✔ $APP"
echo "✔ $DMG"
