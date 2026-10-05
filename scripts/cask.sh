#!/bin/sh
# Prints the Homebrew cask for a release; CI writes it to mikhail-angelov/homebrew-tap on every tag.
# Usage: scripts/cask.sh <version> <sha256 of Vadic-<version>-macos-arm64.zip>
set -eu
version=$1
sha256=$2

cat <<CASK
cask "vadic" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/mikhail-angelov/vadic/releases/download/v#{version}/Vadic-#{version}-macos-arm64.zip"
  name "Vadic"
  desc "Local push-to-talk dictation powered by whisper.cpp"
  homepage "https://github.com/mikhail-angelov/vadic"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"
  depends_on formula: "whisper-cpp"

  app "Vadic.app"

  # Vadic isn't notarized, so Gatekeeper would refuse to open the quarantined download.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Vadic.app"]
  end

  uninstall quit: "dev.vadic.Vadic"

  zap trash: [
    "~/Library/Application Support/Vadic",
    "~/Library/Preferences/dev.vadic.Vadic.plist",
  ]
end
CASK
