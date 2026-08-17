#!/usr/bin/env bash
set -euo pipefail
RESOURCES="projectMac/Resources"

TEMP="$(mktemp -d)"
pushd "$TEMP" >/dev/null

git clone https://github.com/projectM-visualizer/presets-cream-of-the-crop.git
mkdir -p "${OLDPWD}/${RESOURCES}/Presets"
cp -R presets-cream-of-the-crop/. "${OLDPWD}/${RESOURCES}/Presets/"

git clone https://github.com/projectM-visualizer/presets-milkdrop-texture-pack.git
mkdir -p "${OLDPWD}/${RESOURCES}/Textures"
cp -R presets-milkdrop-texture-pack/textures/. "${OLDPWD}/${RESOURCES}/Textures/"

popd >/dev/null
rm -rf "$TEMP"
echo "Done. Add Resources/Presets and Resources/Textures to the Xcode target."
