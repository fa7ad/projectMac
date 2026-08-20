#!/usr/bin/env bash
# Shared config and helpers. Sourced, never executed.

APP_NAME="projectMac"
SCHEME="projectMac"
PROJECT="$APP_NAME.xcodeproj"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESOURCES_DIR="$REPO_ROOT/projectMac/Resources"
PRESETS_DIR="$RESOURCES_DIR/Presets"
TEXTURES_DIR="$RESOURCES_DIR/Textures"
# shellcheck disable=SC2034  # used by package.sh
DIST_DIR="$REPO_ROOT/dist"

# xcode_build passes this through as PROJECTM_PREFIX, which project.yml's search
# paths are written in terms of.
PREFIX="${PREFIX:-/usr/local}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null \
      || die "$tool not found. Install the build tools: brew install cmake xcodegen glm"
  done
}

require_libprojectm() {
  if [ ! -f "$PREFIX/lib/libprojectM-4.a" ] || [ ! -d "$PREFIX/include/projectM-4" ]; then
    die "libprojectM 4.x not found in $PREFIX. Build it first: scripts/deps.sh"
  fi
}

# Existence, not contents: CI plants empty placeholders to skip the fetch.
ensure_resources() {
  if [ -d "$PRESETS_DIR" ] && [ -d "$TEXTURES_DIR" ]; then
    return
  fi
  log "Presets/textures missing, fetching"
  "$REPO_ROOT/scripts/fetch-resources.sh"
}

generate_project() {
  require_tools xcodegen
  log "Generating $PROJECT from project.yml"
  xcodegen generate
}

# xcode_build [--configuration NAME] [--unsigned] [--derived-data DIR] [-- extra args]
xcode_build() {
  local configuration="Debug" unsigned=0 derived_data="" extra=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --configuration) configuration="$2"; shift 2 ;;
      --unsigned)      unsigned=1; shift ;;
      --derived-data)  derived_data="$2"; shift 2 ;;
      --)              shift; extra=("$@"); break ;;
      *)               die "xcode_build: unexpected argument '$1'" ;;
    esac
  done

  require_tools xcodebuild
  require_libprojectm

  local args=(-project "$PROJECT" -scheme "$SCHEME" -configuration "$configuration")
  [ -n "$derived_data" ] && args+=(-derivedDataPath "$derived_data")
  args+=(build "PROJECTM_PREFIX=$PREFIX")
  [ "$unsigned" -eq 1 ] && args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  [ ${#extra[@]} -gt 0 ] && args+=("${extra[@]}")

  log "Building $SCHEME ($configuration)${derived_data:+ into $derived_data}"
  xcodebuild "${args[@]}"
}
