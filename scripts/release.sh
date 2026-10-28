#!/bin/bash
# Builds a universal, Developer ID–signed and notarized Atus.dmg and publishes it
# as a GitHub release.
#
#   ./scripts/release.sh 0.1.0
#
# Credentials come from the environment, or from an untracked ./release.env
# (see release.env.example):
#   ATUS_DEVID_P12, ATUS_DEVID_P12_PASSWORD     Developer ID Application cert + key (.p12)
#   ATUS_NOTARY_KEY, ATUS_NOTARY_KEY_ID,        App Store Connect API key (.p8) used by notarytool
#   ATUS_NOTARY_ISSUER
# The .p12 is imported into a throwaway keychain for the duration of the run, so the
# login keychain is never modified.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>, e.g. 0.1.0}"
TAG="v$VERSION"
APP=build/Atus.app
DMG=dist/Atus.dmg

fail() { echo "error: $*" >&2; exit 1; }

if [[ -f release.env ]]; then
  # shellcheck disable=SC1091
  source release.env
fi
for var in ATUS_DEVID_P12 ATUS_DEVID_P12_PASSWORD ATUS_NOTARY_KEY ATUS_NOTARY_KEY_ID ATUS_NOTARY_ISSUER; do
  [[ -n "${!var:-}" ]] || fail "$var is not set (see release.env.example)"
done
[[ -f "$ATUS_DEVID_P12" ]] || fail "ATUS_DEVID_P12 not found: $ATUS_DEVID_P12"
[[ -f "$ATUS_NOTARY_KEY" ]] || fail "ATUS_NOTARY_KEY not found: $ATUS_NOTARY_KEY"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "release from main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"

NOTARY_AUTH=(--key "$ATUS_NOTARY_KEY" --key-id "$ATUS_NOTARY_KEY_ID" --issuer "$ATUS_NOTARY_ISSUER")
xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null || fail "notarytool rejected the App Store Connect API key"

# Throwaway keychain holding the Developer ID identity; removed and the search list restored on exit.
WORK="$(mktemp -d)"
KEYCHAIN="$WORK/atus-release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  ORIGINAL_KEYCHAINS+=("${line//\"/}")
done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$ATUS_DEVID_P12" -k "$KEYCHAIN" -P "$ATUS_DEVID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/Developer ID Application/ { print $2; exit }')"
[[ -n "$IDENTITY" ]] || fail "no valid 'Developer ID Application' identity in $ATUS_DEVID_P12"

# Submits a file for notarization and fails unless Apple accepts it.
notarize() {
  local file="$1" result id
  result="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json)"
  id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"$result")"
  if ! grep -q '"status":"Accepted"' <<<"$result"; then
    echo "$result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2
    fail "notarization rejected: $file"
  fi
}

swift test
ATUS_UNIVERSAL=1 ATUS_VERSION="$VERSION" ATUS_SIGN_IDENTITY="$IDENTITY" ./scripts/bundle.sh

ditto -c -k --keepParent "$APP" "$WORK/Atus.zip"
notarize "$WORK/Atus.zip"
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
