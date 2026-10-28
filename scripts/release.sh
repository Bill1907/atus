#!/bin/bash
# Builds a universal, Developer ID–signed and notarized Atus.dmg and publishes it
# as a GitHub release.
#
#   ./scripts/release.sh 0.1.0
#
# One-time setup (see README → Releasing):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials: xcrun notarytool store-credentials atus-notary ...
#   - gh CLI logged in with push access
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>, e.g. 0.1.0}"
TAG="v$VERSION"
NOTARY_PROFILE="${ATUS_NOTARY_PROFILE:-atus-notary}"
APP=build/Atus.app
DMG=dist/Atus.dmg

fail() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "release from main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"

IDENTITY="${ATUS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
[[ -n "$IDENTITY" ]] || fail "no 'Developer ID Application' certificate in the keychain (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notarytool profile '$NOTARY_PROFILE' missing or invalid (xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific password>)"

# Submits a file for notarization and fails unless Apple accepts it.
notarize() {
  local file="$1" result id
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"$result")"
  if ! grep -q '"status":"Accepted"' <<<"$result"; then
    echo "$result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    fail "notarization rejected: $file"
  fi
}

swift test
ATUS_UNIVERSAL=1 ATUS_VERSION="$VERSION" ATUS_SIGN_IDENTITY="$IDENTITY" ./scripts/bundle.sh

ZIP=build/Atus-notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

./scripts/make-dmg.sh "$APP" "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

git tag -a "$TAG" -m "Atus $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --title "Atus $VERSION" --generate-notes
echo "Released $TAG: $(gh release view "$TAG" --json url -q .url)"
