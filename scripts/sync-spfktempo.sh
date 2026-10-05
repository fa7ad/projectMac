#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

UPSTREAM_URL="https://github.com/ryanfrancesconi/spfk-tempo"
DEST="$REPO_ROOT/projectMac/SceneStream/SPFKTempo"
PIN_FILE="$REPO_ROOT/scripts/spfktempo.rev"

usage() {
  cat <<USAGE
Usage: scripts/sync-spfktempo.sh [REV] [options]

Updates the vendored SPFKTempo engine (projectMac/SceneStream/SPFKTempo/) from
$UPSTREAM_URL. Replaces the upstream files and LICENSE, keeps
projectMac's own BpmDetection+Live.swift, and records the revision in
scripts/spfktempo.rev (kept out of the Xcode sources so it is not bundled).

Arguments:
  REV             Upstream branch, tag or commit. Defaults to upstream's default branch.

Options:
      --check     Only report whether upstream has moved past the pinned revision.
  -h, --help      Show this help.

After syncing, build (scripts/build.sh): BpmDetection+Live.swift reaches into the
engine's internal state, so an upstream rename shows up as a compile error there.
USAGE
}

REV=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; die "unknown option '$1'" ;;
    *)
      [ -n "$REV" ] && { usage >&2; die "unexpected argument '$1'"; }
      REV="$1"; shift ;;
  esac
done

require_tools git rsync
PINNED="$(tr -d '[:space:]' < "$PIN_FILE" 2>/dev/null || true)"

if [ "$CHECK" -eq 1 ]; then
  LATEST="$(git ls-remote "$UPSTREAM_URL" HEAD | cut -f1)"
  [ -n "$LATEST" ] || die "could not reach $UPSTREAM_URL"
  log "pinned:   ${PINNED:-unknown}"
  log "upstream: $LATEST"
  [ "$PINNED" = "$LATEST" ] && log "up to date" || log "upstream has moved"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log "Fetching $UPSTREAM_URL${REV:+ @ $REV}"
git clone -q "$UPSTREAM_URL" "$WORK/spfk"
[ -z "$REV" ] || git -C "$WORK/spfk" checkout -q "$REV"
NEW="$(git -C "$WORK/spfk" rev-parse HEAD)"

SRC="$WORK/spfk/Sources/SPFKTempo/BpmDetection"
[ -d "$SRC" ] || die "upstream layout changed: $SRC not found"

# Only the BpmDetection engine is vendored, not BpmAnalysis (file-level analysis).
rsync -a --delete --exclude 'BpmDetection+Live.swift' --exclude LICENSE.txt "$SRC/" "$DEST/"
cp "$WORK/spfk/LICENSE" "$DEST/LICENSE.txt"
echo "$NEW" > "$PIN_FILE"

log "Synced SPFKTempo ${PINNED:-unknown} -> $NEW"
git status --short -- "$DEST"
