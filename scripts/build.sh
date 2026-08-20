#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

usage() {
  cat <<EOF
Usage: scripts/build.sh [CONFIGURATION] [options] [-- xcodebuild args...]

Generates the Xcode project from project.yml and builds the app.

Arguments:
  CONFIGURATION       Debug (default) or Release. Also settable with -c.

Options:
  -c, --configuration NAME   Build configuration.
      --unsigned             Disable code signing (what CI uses).
      --with-deps            Build libprojectM and fetch presets/textures first.
  -h, --help                 Show this help.

Examples:
  scripts/build.sh
  scripts/build.sh Release
  scripts/build.sh --unsigned
  scripts/build.sh --with-deps
  scripts/build.sh -- -quiet
EOF
}

CONFIGURATION="Debug"
UNSIGNED=0
WITH_DEPS=0
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--configuration) CONFIGURATION="$2"; shift 2 ;;
    --unsigned)         UNSIGNED=1; shift ;;
    --with-deps)        WITH_DEPS=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    --)                 shift; EXTRA=("$@"); break ;;
    Debug|Release)      CONFIGURATION="$1"; shift ;;
    *)                  usage >&2; die "unknown argument '$1'" ;;
  esac
done

if [ "$WITH_DEPS" -eq 1 ]; then
  "$REPO_ROOT/scripts/deps.sh"
  "$REPO_ROOT/scripts/fetch-resources.sh"
fi

ensure_resources
generate_project

BUILD_ARGS=(--configuration "$CONFIGURATION")
[ "$UNSIGNED" -eq 1 ] && BUILD_ARGS+=(--unsigned)
[ ${#EXTRA[@]} -gt 0 ] && BUILD_ARGS+=(-- "${EXTRA[@]}")

xcode_build "${BUILD_ARGS[@]}"
