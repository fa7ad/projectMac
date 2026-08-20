#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

usage() {
  cat <<EOF
Usage: scripts/package.sh [VERSION] [options]

Builds a Release configuration and packages it into dist/.

Arguments:
  VERSION         Version string used in output filenames.
                  Defaults to \`git describe --tags --always --dirty\`.

Options:
      --no-dmg    Emit dist/$APP_NAME-VERSION.app instead of a DMG.
  -h, --help      Show this help.

Examples:
  scripts/package.sh                    # dist/$APP_NAME-<version>.dmg
  scripts/package.sh v0.2.0 --no-dmg    # dist/$APP_NAME-v0.2.0.app
EOF
}

VERSION=""
WANT_DMG=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-dmg)  WANT_DMG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; die "unknown option '$1'" ;;
    *)
      [ -n "$VERSION" ] && { usage >&2; die "unexpected argument '$1'"; }
      VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"

BUILD_DIR="$(mktemp -d)"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGING_DIR"' EXIT

ensure_resources
generate_project
xcode_build --configuration Release --derived-data "$BUILD_DIR"

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || die "expected a built app at $APP_PATH"

mkdir -p "$DIST_DIR"

if [ "$WANT_DMG" -eq 1 ]; then
  cp -R "$APP_PATH" "$STAGING_DIR/"
  ln -s /Applications "$STAGING_DIR/Applications"

  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
  log "Created $DMG_PATH"
else
  DEST_APP="$DIST_DIR/$APP_NAME-$VERSION.app"
  rm -rf "$DEST_APP"
  cp -R "$APP_PATH" "$DEST_APP"
  log "Created $DEST_APP"
fi
