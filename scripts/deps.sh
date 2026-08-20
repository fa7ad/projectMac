#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

# Builds libprojectM 4.x from source into $PREFIX. Also run by CI
# (.github/actions/setup-build), so keep the cmake invocation here only.

REPO="https://github.com/projectM-visualizer/projectm.git"
SRC_DIR="$REPO_ROOT/vendor/projectm"
BUILD_DIR="$SRC_DIR/build"

require_tools git cmake

if [ -d "$SRC_DIR/.git" ]; then
  log "Updating $SRC_DIR"
  git -C "$SRC_DIR" pull --ff-only
else
  log "Cloning libprojectM into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" submodule update --init

log "Configuring libprojectM (prefix $PREFIX, deployment target $DEPLOYMENT_TARGET)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=ON -DENABLE_TESTING=OFF -DENABLE_SDL_UI=OFF \
  -DENABLE_SYSTEM_GLM=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
cmake --build "$BUILD_DIR" --parallel

if [ -w "$PREFIX" ]; then
  cmake --install "$BUILD_DIR"
else
  log "$PREFIX is not writable, installing with sudo"
  sudo cmake --install "$BUILD_DIR"
fi

log "Installed libprojectM into $PREFIX"
