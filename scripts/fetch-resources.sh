#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

# Fetches presets and textures into projectMac/Resources (gitignored, not vendored).

require_tools git

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

log "Fetching presets"
git clone --depth 1 https://github.com/projectM-visualizer/presets-cream-of-the-crop.git \
  "$TEMP/presets"
rm -rf "$PRESETS_DIR"
mkdir -p "$PRESETS_DIR"
cp -R "$TEMP/presets/." "$PRESETS_DIR/"
rm -rf "$PRESETS_DIR/.git"

log "Fetching textures"
git clone --depth 1 https://github.com/projectM-visualizer/presets-milkdrop-texture-pack.git \
  "$TEMP/textures"
rm -rf "$TEXTURES_DIR"
mkdir -p "$TEXTURES_DIR"
cp -R "$TEMP/textures/textures/." "$TEXTURES_DIR/"

log "Presets: $(find "$PRESETS_DIR" -type f | wc -l | tr -d ' ') files in $PRESETS_DIR"
log "Textures: $(find "$TEXTURES_DIR" -type f | wc -l | tr -d ' ') files in $TEXTURES_DIR"
