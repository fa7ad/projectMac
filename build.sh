#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-Debug}"
WITH_DEPENDENCIES="${WITH_DEPENDENCIES:-0}"

if [ "$WITH_DEPENDENCIES" -eq 1 ]; then
    ./build-libprojectm.sh
    ./fetch-resources.sh
fi

xcodegen generate
xcodebuild -project projectMac.xcodeproj -scheme projectMac -configuration "$CONFIGURATION" build
