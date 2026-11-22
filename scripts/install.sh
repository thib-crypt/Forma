#!/bin/zsh
# Build Forma (Release), install it in /Applications and register its Finder and Share extensions.
#   scripts/install.sh            build + install + relaunch
#   scripts/install.sh --no-build install the last build
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME=Forma
BUILD_DIR=build-release
BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
FINDER_ID=com.thibault.forma.FinderMenu
SHARE_ID=com.thibault.forma.Share
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ "${1:-}" != "--no-build" ]]; then
  xcodegen generate --quiet
  xcodebuild -scheme Forma -configuration Release -derivedDataPath "$BUILD_DIR" build -quiet
fi
codesign --verify --deep --strict "$BUILT"

# Quit the running copy (it finishes or cancels its batch first).
if pgrep -xq "$APP_NAME"; then  # whichever copy is running
  osascript -e "tell application id \"com.thibault.forma\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq "$APP_NAME" || break; sleep 0.25; done
  pkill -x "$APP_NAME" 2>/dev/null || true
fi

# The build folder copies (Release and Debug) must never be the ones Launch Services / PlugInKit picks:
# an extension living in a build copy wakes that copy, i.e. a second Forma next to /Applications.
for copy in "$BUILT" build/Build/Products/Debug/$APP_NAME.app; do
  [[ -d "$copy" ]] || continue
  for appex in "$copy"/Contents/PlugIns/*.appex(N); do pluginkit -r "$appex" 2>/dev/null || true; done
  "$LSREGISTER" -u "$copy" 2>/dev/null || true
done

rm -rf "$DEST"
ditto "$BUILT" "$DEST"
"$LSREGISTER" -f -R "$DEST"

for appex in "$DEST"/Contents/PlugIns/*.appex(N); do pluginkit -a "$appex"; done
pluginkit -e use -i "$FINDER_ID" || true
pluginkit -e use -i "$SHARE_ID" || true

echo "Installé : $DEST ($(defaults read "$DEST/Contents/Info" CFBundleShortVersionString))"
pluginkit -m -v -i "$FINDER_ID" || true
pluginkit -m -v -i "$SHARE_ID" || true

open -g "$DEST" --args --headless
