#!/usr/bin/env bash
set -euo pipefail

# Clones libprojectM 4.x into vendor/projectm and installs it into $PREFIX.
# Homebrew's `projectm` cask is 3.1.x with an old C++ API; this project needs
# 4.x's C API, so it has to come from source.
#
# Also used by CI (.github/actions/setup-build), so this is the only place the
# cmake invocation lives.

REPO="https://github.com/projectM-visualizer/projectm.git"
SRC_DIR="vendor/projectm"
BUILD_DIR="$SRC_DIR/build"
PREFIX="${PREFIX:-/usr/local}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"

for tool in git cmake; do
  command -v "$tool" >/dev/null || { echo "$tool not found (brew install cmake)" >&2; exit 1; }
done

if [ -d "$SRC_DIR/.git" ]; then
  git -C "$SRC_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" submodule update --init

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=ON -DENABLE_TESTING=OFF -DENABLE_SDL_UI=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
cmake --build "$BUILD_DIR" --parallel

if [ -w "$PREFIX" ]; then
  cmake --install "$BUILD_DIR"
else
  sudo cmake --install "$BUILD_DIR"
fi

echo "Installed libprojectM into $PREFIX"
