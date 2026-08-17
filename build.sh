#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-Debug}"

xcodegen generate
xcodebuild -project projectMac.xcodeproj -scheme projectMac -configuration "$CONFIGURATION" build
