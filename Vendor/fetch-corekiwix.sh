#!/bin/zsh
# Downloads Kiwix's prebuilt CoreKiwix.xcframework (libkiwix + libzim + Xapian + ICU, GPLv3)
# and checks it against Kiwix's published MD5. It's 200 MB unpacked, so it isn't kept in git.
set -euo pipefail
VERSION=14.2.1-2
NAME=libkiwix_xcframework-$VERSION.tar.gz
URL=https://download.kiwix.org/release/libkiwix/$NAME
DEST=${0:A:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $NAME…"
curl -fL --progress-bar -o "$WORK/$NAME" "$URL"
curl -fsL -o "$WORK/$NAME.md5" "$URL.md5"
expected=$(awk '{print $1}' "$WORK/$NAME.md5")
actual=$(md5 -q "$WORK/$NAME")
[[ "$expected" == "$actual" ]] || { echo "Checksum mismatch: expected $expected, got $actual" >&2; exit 1; }
echo "Checksum OK ($actual)"

tar -xzf "$WORK/$NAME" -C "$WORK"
found=$(find "$WORK" -maxdepth 3 -type d -name 'CoreKiwix.xcframework' | head -1)
[[ -n "$found" ]] || { echo "CoreKiwix.xcframework not found in the archive" >&2; exit 1; }
rm -rf "$DEST/CoreKiwix.xcframework"
mv "$found" "$DEST/CoreKiwix.xcframework"
echo "Installed $DEST/CoreKiwix.xcframework"
