#!/usr/bin/env bash
# Builds a release binary and wraps it in build/DisplayTool.app (menu bar only, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/DisplayTool.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DisplayTool" "$APP/Contents/MacOS/DisplayTool"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
