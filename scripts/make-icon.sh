#!/bin/sh
# Regenerates Resources/AppIcon.icns and docs/icon.png from scripts/make-icon.swift.
set -eu
cd "$(dirname "$0")/.."

set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  swift scripts/make-icon.swift "$set_dir/icon_${size}x${size}.png" "$size"
  swift scripts/make-icon.swift "$set_dir/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
cp "$set_dir/icon_256x256@2x.png" docs/icon.png
echo "wrote Resources/AppIcon.icns and docs/icon.png"
