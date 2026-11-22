#!/bin/zsh
# Builds a signed, notarized DMG and (optionally) publishes it as a GitHub Release.
#
#   scripts/release.sh              → dist/Forma-<version>.dmg, signed + notarized + stapled
#   scripts/release.sh --publish    → same, then tags v<version> and creates the GitHub Release
#   NOTARIZE=0 scripts/release.sh   → skip notarization (local test only; Gatekeeper will block it elsewhere)
#
# One-time setup (stores an app-specific password in the Keychain):
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id PG46BWSK3T
# The version comes from MARKETING_VERSION in project.yml.
set -euo pipefail
cd "${0:A:h}/.."

APP=Forma
SCHEME=Forma
BUILD_DIR=build-release
SIGN_ID="${SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
PUBLISH=0; [[ "${1:-}" == "--publish" ]] && PUBLISH=1

if (( PUBLISH )); then
  [[ -z "$(git status --porcelain)" ]] || { echo "✗ Uncommitted changes: commit before publishing." >&2; exit 1; }
fi

echo "→ Building $APP (Release)…"
xcodegen generate --quiet
rm -rf "$BUILD_DIR"
# Notarization requires the hardened runtime and a secure timestamp on every binary.
xcodebuild -scheme "$SCHEME" -configuration Release -derivedDataPath "$BUILD_DIR" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build -quiet

BUILT="$BUILD_DIR/Build/Products/Release/$APP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
codesign --verify --deep --strict "$BUILT"

# The release copy must not be picked by Launch Services / PlugInKit (see install.sh).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for appex in "$BUILT"/Contents/PlugIns/*.appex(N); do pluginkit -r "$appex" 2>/dev/null || true; done
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true

echo "→ Packaging $APP $VERSION…"
mkdir -p dist
DMG="dist/$APP-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$BUILT" "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGE"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

if [[ "${NOTARIZE:-1}" != "0" ]]; then
  echo "→ Notarizing (profile « $NOTARY_PROFILE »)…"
  LOG=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  print -r -- "$LOG"
  grep -q "status: Accepted" <<<"$LOG" || { echo "✗ Notarization failed (xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)." >&2; exit 1; }
  xcrun stapler staple -q "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "✓ $DMG"
echo "  sha256 $SHA"

if (( PUBLISH )); then
  TAG="v$VERSION"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "✗ Tag $TAG already exists: bump MARKETING_VERSION." >&2; exit 1; }
  git tag -a "$TAG" -m "$APP $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" --verify-tag --title "$APP $VERSION" --generate-notes
  echo "✓ Published $TAG"
fi
