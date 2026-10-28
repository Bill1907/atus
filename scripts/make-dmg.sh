#!/bin/bash
# Packages an app bundle into a drag-to-Applications disk image.
#   ./scripts/make-dmg.sh build/Atus.app dist/Atus-1.0.0.dmg
set -euo pipefail

APP="$1"
DMG="$2"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -quiet -volname Atus -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
echo "Created $DMG"
