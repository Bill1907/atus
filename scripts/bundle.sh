#!/bin/bash
# Builds build/Atus.app (release, ad-hoc signed). Pass --open to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP=build/Atus.app

pkill -x Atus 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Atus" "$APP/Contents/MacOS/Atus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
