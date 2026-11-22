#!/bin/zsh
# Builds a signed, notarized DMG and (optionally) publishes it as a GitHub Release.
#
#   scripts/release.sh              → dist/Forma-<version>.dmg, signed + notarized + stapled
#   scripts/release.sh --publish    → same, then tags v<version> and creates the GitHub Release
#   NOTARIZE=0 scripts/release.sh   → skip notarization (local test only; Gatekeeper will block it elsewhere)
#   RELEASE_NOTES=notes.md scripts/release.sh --publish   → your own notes instead of the commit list
#
# Updates: --publish also commits appcast.xml (the Sparkle feed the installed apps check daily).
# Only the marketing version needs bumping; the build number is the commit count.
#
# One-time setup (stores an app-specific password in the Keychain):
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id PG46BWSK3T
# The version comes from MARKETING_VERSION in project.yml.
set -euo pipefail
cd "${0:A:h}/.."

APP=Forma
SCHEME=Forma
BUILD_DIR=build-release
SPARKLE_ARTIFACTS="$BUILD_DIR/SourcePackages/artifacts"
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
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" build -quiet

BUILT="$BUILD_DIR/Build/Products/Release/$APP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
# Sparkle's helpers come ad hoc signed from SwiftPM: re-sign them with our Developer ID, inside out, then the app.
# The app is not sandboxed, so Sparkle's XPC services are not needed.
FW="$BUILT/Contents/Frameworks/Sparkle.framework"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
for target in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$target"
done
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
  --preserve-metadata=identifier,entitlements,requirements,flags "$BUILT"
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

# ── Sparkle appcast ──────────────────────────────────────────────────────────────
# The apps read https://raw.githubusercontent.com/thib-crypt/$APP/main/appcast.xml (SUFeedURL).
# sign_update signs the DMG with the EdDSA private key stored in the Keychain (generate_keys, once).
TAG="v$VERSION"
REPO="thib-crypt/$APP"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$BUILT/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$BUILT/Contents/Info.plist")
SIGN_UPDATE=$(find "$SPARKLE_ARTIFACTS" -path "*/bin/sign_update" -type f 2>/dev/null | head -1)
[[ -x "$SIGN_UPDATE" ]] || { echo "✗ sign_update not found under $SPARKLE_ARTIFACTS." >&2; exit 1; }
ED_ATTRS=$("$SIGN_UPDATE" "$DMG")

# Release notes (Markdown list, shown in the update window and on the GitHub Release):
# RELEASE_NOTES=<file> if given, otherwise the commit subjects since the previous tag.
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
NOTES="dist/notes-$VERSION.md"
if [[ -n "${RELEASE_NOTES:-}" ]]; then cp "$RELEASE_NOTES" "$NOTES"; else
git log --no-merges --format='- %s' ${PREV_TAG:+$PREV_TAG..}HEAD | grep -vE '^- (Appcast|Merge)' > "$NOTES" || true; fi
[[ -s "$NOTES" ]] || echo "- Améliorations et corrections" > "$NOTES"
NOTES_HTML=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/^- \(.*\)$/<li>\1<\/li>/' "$NOTES")

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$APP $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<ul>
$NOTES_HTML
</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$APP-$VERSION.dmg" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "✓ dist/appcast.xml (build $BUILD_NUMBER)"

if (( PUBLISH )); then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "✗ Tag $TAG already exists: bump the version." >&2; exit 1; }
  if [[ -f appcast.xml ]]; then
    PUBLISHED=$(sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' appcast.xml | head -1)
    (( BUILD_NUMBER > ${PUBLISHED:-0} )) || { echo "✗ Build $BUILD_NUMBER is not newer than the published $PUBLISHED." >&2; exit 1; }
  fi
  git tag -a "$TAG" -m "$APP $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" --repo "$REPO" --verify-tag --title "$APP $VERSION" --notes-file "$NOTES"
  # The feed goes live last, once the DMG it points to is downloadable.
  cp dist/appcast.xml appcast.xml
  git add appcast.xml
  git commit -q -m "Appcast $APP $VERSION"
  git push origin HEAD
  echo "✓ Published $TAG — installed copies will be offered the update."
fi
