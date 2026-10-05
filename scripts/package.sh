#!/bin/sh
# Packages build/Vadic.app for a release: a DMG to drag into Applications, a zip for Homebrew, and SHA256SUMS.
# Usage: scripts/package.sh <version>   (run scripts/build-app.sh first)
set -eu
cd "$(dirname "$0")/.."
version=$1
name="Vadic-$version-macos-arm64"

rm -rf dist
mkdir -p dist/dmg
# ditto keeps the bundle's symlinks, extended attributes and signature intact; cp -R and plain zip do not.
ditto build/Vadic.app dist/dmg/Vadic.app
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname Vadic -srcfolder dist/dmg -fs HFS+ -format UDZO "dist/$name.dmg"
rm -rf dist/dmg

ditto -c -k --keepParent build/Vadic.app "dist/$name.zip"
(cd dist && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS)
ls -l dist
