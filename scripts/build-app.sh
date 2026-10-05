#!/bin/sh
# Builds build/Vadic.app. Without a bundle + Info.plist macOS will not grant microphone access.
# TCC ties grants to the designated requirement. Ad-hoc signing defaults it to the cdhash, which changes
# on every build, so pin it to the bundle id. SIGN_IDENTITY=<cert> signs with a real certificate instead.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
app=build/Vadic.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Vadic "$app/Contents/MacOS/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/"
# Release builds stamp the version from the tag (VERSION=1.2.0) and the CI run number (BUILD=42).
if [ -n "${VERSION:-}" ]; then plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"; fi
if [ -n "${BUILD:-}" ]; then plutil -replace CFBundleVersion -string "$BUILD" "$app/Contents/Info.plist"; fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier dev.vadic.Vadic "$app"
else
  codesign --force --sign - --identifier dev.vadic.Vadic -r='designated => identifier "dev.vadic.Vadic"' "$app"
fi
echo "built $app"
