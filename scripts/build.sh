#!/bin/zsh
# Builds Release and installs to /Applications. Uses Xcode directly, so xcode-select can stay on the CLT.
# DerivedData lives outside the project: iCloud Drive tags files here with xattrs that codesign rejects.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DERIVED=~/Library/Caches/Screening/DerivedData
xcodegen generate --quiet
xcodebuild -project Screening.xcodeproj -scheme Screening -configuration Release \
  -derivedDataPath "$DERIVED" -quiet build
pkill -x Screening || true
rm -rf /Applications/Screening.app
cp -R "$DERIVED/Build/Products/Release/Screening.app" /Applications/Screening.app
echo "Installed /Applications/Screening.app"
