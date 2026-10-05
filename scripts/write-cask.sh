#!/bin/bash
# Prints the Homebrew cask for a released version: scripts/write-cask.sh <version> <dmg sha256>
# The release workflow writes it to Casks/mosaic.rb in the doctorschmoctor/homebrew-mosaic tap.
set -euo pipefail
VERSION="${1:?usage: write-cask.sh <version> <sha256>}"
SHA256="${2:?usage: write-cask.sh <version> <sha256>}"
REPOSITORY="${GITHUB_REPOSITORY:-doctorschmoctor/Mosaic}"
cat <<EOF
cask "mosaic" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPOSITORY}/releases/download/v#{version}/Mosaic-#{version}.dmg"
  name "Mosaic"
  desc "Several Messages conversations side by side in one window"
  homepage "https://github.com/${REPOSITORY}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Mosaic.app"

  # The app is signed locally, not notarized: without this, macOS would refuse the first launch
  # until it is allowed in System Settings. Installing from this tap is the user's choice of source.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Mosaic.app"]
  end

  zap trash: [
    "~/Library/Application Support/Mosaic",
    "~/Library/Messages/.mosaic-outgoing",
    "~/Library/Preferences/com.doctorschmoctor.Mosaic.plist",
  ]

  caveats <<~CAVEATS
    Open Mosaic and follow Connect Messages: add Mosaic.app under
    System Settings > Privacy & Security > Full Disk Access, then reopen it.
    After an upgrade, macOS may ask for Full Disk Access again.
  CAVEATS
end
EOF
