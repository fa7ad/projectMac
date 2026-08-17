#!/usr/bin/env bash
set -euo pipefail

APP_NAME="projectMac"
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
DIST_DIR="dist"
BUILD_DIR="$(mktemp -d)"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGING_DIR"' EXIT

if [ ! -d "projectMac/Resources/Presets" ] || [ ! -d "projectMac/Resources/Textures" ]; then
  ./fetch-resources.sh
fi

xcodegen generate
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Created $DMG_PATH"
