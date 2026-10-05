#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

# Builds libprojectM 4.x from source into $PREFIX. Also run by CI
# (.github/actions/setup-build), so keep the cmake invocation here only.

SRC_DIR="$REPO_ROOT/vendor/projectm"
BUILD_DIR="$SRC_DIR/build"

require_tools git cmake

if [ -d "$SRC_DIR/.git" ]; then
  log "Updating $SRC_DIR to $PROJECTM_REPO @ $PROJECTM_REF"
  git -C "$SRC_DIR" remote set-url origin "$PROJECTM_REPO"
else
  log "Cloning libprojectM into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$PROJECTM_REPO"
fi
git -C "$SRC_DIR" fetch --quiet origin "$PROJECTM_REF"
git -C "$SRC_DIR" checkout --quiet --detach FETCH_HEAD
git -C "$SRC_DIR" submodule update --init

log "Configuring libprojectM (prefix $PREFIX, deployment target $DEPLOYMENT_TARGET)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=ON -DENABLE_TESTING=OFF -DENABLE_SDL_UI=OFF \
  -DENABLE_SYSTEM_GLM=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
cmake --build "$BUILD_DIR" --parallel

mkdir -p "$PREFIX" 2>/dev/null || true
if [ -w "$PREFIX" ]; then
  cmake --install "$BUILD_DIR"
else
  log "$PREFIX is not writable, installing with sudo"
  sudo cmake --install "$BUILD_DIR"
fi

log "Installed libprojectM into $PREFIX"
