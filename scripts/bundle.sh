#!/bin/bash
# Builds build/Atus.app from source.
#
#   ./scripts/bundle.sh             build (host arch, ad-hoc signed)
#   ./scripts/bundle.sh --open      build and launch from build/
#   ./scripts/bundle.sh --install   build, copy to /Applications, launch
#
# Environment (used by release.sh):
#   ATUS_UNIVERSAL=1          build arm64 + x86_64
#   ATUS_VERSION=1.2.3        CFBundleShortVersionString (default: Info.plist)
#   ATUS_SIGN_IDENTITY=...    codesign identity; "-" (default) = ad-hoc.
#                             A real identity also enables the hardened runtime
#                             and a secure timestamp, as notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-}"
SIGN_IDENTITY="${ATUS_SIGN_IDENTITY:--}"
BUILD_ARGS=(-c release)
if [[ "${ATUS_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP=build/Atus.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Atus" "$APP/Contents/MacOS/Atus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${ATUS_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ATUS_VERSION" "$PLIST"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Atus"), signed: $SIGN_IDENTITY)"

case "$ACTION" in
  --open)
    pkill -x Atus 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x Atus 2>/dev/null || true
    rm -rf /Applications/Atus.app
    ditto "$APP" /Applications/Atus.app
    open /Applications/Atus.app
    echo "Installed /Applications/Atus.app"
    ;;
  "") ;;
  *) echo "unknown option: $ACTION" >&2; exit 2 ;;
esac
