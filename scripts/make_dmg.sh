#!/bin/zsh
# Builds a Release app and packages it as build/Screening-<version>.dmg, without installing it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DERIVED=~/Library/Caches/Screening/DerivedData
xcodegen generate --quiet
xcodebuild -project Screening.xcodeproj -scheme Screening -configuration Release \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" -quiet build

APP="$DERIVED/Build/Products/Release/Screening.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Screening-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Screening.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p build
rm -f "$DMG"
hdiutil create -quiet -volname "Screening" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
echo "$PWD/$DMG"
