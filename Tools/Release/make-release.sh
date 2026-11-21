#!/bin/zsh
# Builds a signed (and, when credentials are saved, notarized) Offline Kit disk image for sharing.
#
#   Tools/Release/make-release.sh
#
# Signing uses the Developer ID for team QF9W87MQ59 with the hardened runtime.
# Notarization uses a notarytool keychain profile; create it once (it asks for an app-specific password):
#   xcrun notarytool store-credentials offlinekit-notary --apple-id <your Apple ID> --team-id QF9W87MQ59
set -euo pipefail

ROOT=${0:A:h:h:h}
IDENTITY="Developer ID Application: Joey Chappel (QF9W87MQ59)"
PROFILE=${NOTARY_PROFILE:-offlinekit-notary}
cd "$ROOT"

[[ -d Vendor/CoreKiwix.xcframework ]] || Vendor/fetch-corekiwix.sh
[[ -d Vendor/llama.xcframework ]] || Vendor/build-llama.sh

echo "› Building Release"
xcodegen generate -q
xcodebuild -project OfflineKit.xcodeproj -scheme OfflineKit-macOS -configuration Release \
  -derivedDataPath build/release build -quiet
BUILT="build/release/Build/Products/Release/Offline Kit.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")

STAGE=dist/stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$BUILT" "$STAGE/Offline Kit.app"
APP="$STAGE/Offline Kit.app"

# Nothing from this Mac's folders (user name, scratch paths) should ship anywhere in the app.
# A raw byte search: macOS `strings` skips the symbol table, where a debug map keeps full paths.
LEAKS=$(find "$APP" -type f -exec env LC_ALL=C grep -l -a -e "/Users/" -e "/private/tmp/" {} + || true)
if [[ -n $LEAKS ]]; then
  echo "✗ These files contain local folder paths (rebuild with -ffile-prefix-map, or strip the debug map):" >&2
  echo "$LEAKS" >&2
  exit 1
fi

echo "› Signing with $IDENTITY (hardened runtime)"
for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$fw"
done
# The entitlements file gives the hardened runtime microphone access (Ask's hands-free mode); without it capture fails silently.
codesign --force --timestamp --options runtime --entitlements Sources/Mac/OfflineKit.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

HAS_PROFILE=false
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 && HAS_PROFILE=true
if $HAS_PROFILE; then
  # Notarize and staple the app itself too, so a copy dragged out of the disk image passes Gatekeeper offline.
  echo "› Notarizing the app"
  ditto -c -k --keepParent "$APP" dist/app-notarize.zip
  xcrun notarytool submit dist/app-notarize.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f dist/app-notarize.zip
fi

echo "› Packaging"
swift Tools/Release/html2pdf.swift Tools/Release/StartHere.html "$STAGE/Start Here.pdf" >/dev/null 2>&1
# The DMG tool writes its own Finder layout and a relocatable background alias.
# It needs no Finder automation permission and never changes the user's Finder preferences.
DMG_PYTHON=${DMG_PYTHON:-"$ROOT/build/dmg-tools/bin/python"}
if [[ ! -x "$DMG_PYTHON" ]]; then
  if [[ "$DMG_PYTHON" != "$ROOT/build/dmg-tools/bin/python" ]]; then
    echo "✗ DMG_PYTHON must name an executable Python environment." >&2
    exit 1
  fi
  python3 -m venv "$ROOT/build/dmg-tools"
fi
if ! "$DMG_PYTHON" -c 'from importlib.metadata import version; assert version("dmgbuild") == "2.0.0"' >/dev/null 2>&1; then
  "$DMG_PYTHON" -m pip install --disable-pip-version-check -r Tools/Release/requirements-dmg.txt
fi
DMG="dist/OfflineKit-$VERSION.dmg"
rm -f "$DMG"
"$DMG_PYTHON" Tools/Release/build-dmg.py --stage "$STAGE" --output "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if $HAS_PROFILE; then
  echo "› Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  echo "✓ $DMG is signed, notarized and stapled. It opens on other Macs without warnings."
else
  echo "✓ $DMG is signed but NOT notarized (no '$PROFILE' keychain profile)."
  echo "  Without notarization, the other Mac needs System Settings › Privacy & Security › Open Anyway once."
  echo "  To notarize: run the store-credentials command at the top of this script, then run this script again."
fi
du -h "$DMG"
