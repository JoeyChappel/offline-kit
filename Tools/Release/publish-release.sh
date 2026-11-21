#!/bin/zsh
# Publishes the notarized disk image as the newest download on GitHub, after make-release.sh.
#
#   Tools/Release/publish-release.sh                 # the version in project.yml
#   NOTES="What changed" Tools/Release/publish-release.sh 0.2.3
#
# The link to send people always gets the newest build:
#   https://github.com/JoeyChappel/offline-kit/releases/latest/download/OfflineKit.dmg
#
# Each release also carries what the app's built-in updater reads (Sources/Mac/AppUpdater.swift):
#   latest.json             version, build, notes, and the zipped app's address, size and SHA-256
#   OfflineKit-update.zip   the app itself, so updating doesn't mount a disk image
#   OfflineKit-<v>-source.zip  the GPL source for this build (publish-source.sh also pushes it to the repo)
#
# It uploads as the JoeyChappel GitHub account (signed in with `gh auth login`) for this script only;
# the account gh normally uses is left as it is.
set -euo pipefail

ROOT=${0:A:h:h:h}
REPO=${RELEASE_REPO:-JoeyChappel/offline-kit}
ACCOUNT=${RELEASE_ACCOUNT:-JoeyChappel}
cd "$ROOT"

VERSION=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)}
DMG="dist/OfflineKit-$VERSION.dmg"
[[ -f $DMG ]] || { echo "✗ No $DMG. Run Tools/Release/make-release.sh first." >&2; exit 1; }

# Only notarized builds go out: other Macs refuse to open anything else without a trip to System Settings.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1 ||
   ! spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1; then
  echo "✗ $DMG isn't notarized. Save the notary login and run make-release.sh again." >&2
  exit 1
fi

export GH_TOKEN=$(gh auth token --user "$ACCOUNT")
TAG="v$VERSION"
NOTES=${NOTES:-"Offline Kit $VERSION for Mac (Apple silicon). Open the disk image and drag Offline Kit to Applications."}

# Every release carries the same file names, so the "latest" links never change.
TMP=$(mktemp -d)
MOUNT="$TMP/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null; rm -rf "$TMP"' EXIT
cp "$DMG" "$TMP/OfflineKit.dmg"

echo "› Zipping the app for in-app updates"
mkdir -p "$MOUNT"
hdiutil attach -readonly -nobrowse -noautoopen -quiet -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/Offline Kit.app"
xcrun stapler validate "$APP" >/dev/null   # the updater installs this copy, so it must be stapled too
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
ditto -c -k --keepParent "$APP" "$TMP/OfflineKit-update.zip"
hdiutil detach "$MOUNT" -quiet

ZIP_URL="https://github.com/$REPO/releases/download/$TAG/OfflineKit-update.zip"
/usr/bin/python3 -I - "$TMP/latest.json" "$VERSION" "$BUILD" "$ZIP_URL" "$TMP/OfflineKit-update.zip" "$NOTES" "$MIN_SYSTEM" <<'PY'
import hashlib, json, os, sys
out, version, build, url, zip_path, notes, min_system = sys.argv[1:]
digest = hashlib.sha256()
with open(zip_path, "rb") as f:
    for block in iter(lambda: f.read(8 << 20), b""):
        digest.update(block)
with open(out, "w") as f:
    json.dump({"version": version, "build": int(build), "url": url, "sha256": digest.hexdigest(),
               "size": os.path.getsize(zip_path), "notes": notes, "minimumSystem": min_system}, f, indent=2)
PY

# The GPL source for this build goes up first, so the release's tag lands on the matching source commit.
"$ROOT/Tools/Release/publish-source.sh" "$VERSION"
SOURCE_ZIP="dist/OfflineKit-$VERSION-source.zip"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "› Replacing the files on $TAG"
  gh release upload "$TAG" "$TMP/OfflineKit.dmg" "$TMP/OfflineKit-update.zip" -R "$REPO" --clobber
else
  echo "› Publishing $TAG"
  gh release create "$TAG" "$TMP/OfflineKit.dmg" "$TMP/OfflineKit-update.zip" "$SOURCE_ZIP" -R "$REPO" \
    --target main --title "Offline Kit $VERSION" --notes "$NOTES" --latest
fi
# Last, so the app never hears about a build whose files aren't up yet.
gh release upload "$TAG" "$TMP/latest.json" -R "$REPO" --clobber

echo "✓ https://github.com/$REPO/releases/latest/download/OfflineKit.dmg"
