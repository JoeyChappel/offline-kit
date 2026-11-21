#!/usr/bin/env bash
#
# Reproducibly builds Vendor/llama.xcframework from llama.cpp at a pinned commit.
# Slices: macOS arm64, iOS device arm64, iOS simulator arm64. Metal shaders embedded.
# Requires: git, cmake (3.28+), Xcode command line tools.
#
# usage: Vendor/build-llama.sh [WORK_DIR]   (default WORK_DIR: Vendor/.build-llama, delete freely)
set -euo pipefail

LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_TAG="v1.0.0-b12359-b1b770d"
LLAMA_COMMIT="b1b770d90d94cad9e9ea5b993bdbc383a522fb28"
MACOS_MIN="14.0"
IOS_MIN="17.0"

VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${1:-$VENDOR_DIR/.build-llama}"
OUT="$VENDOR_DIR/llama.xcframework"
SRC="$WORK_DIR/llama.cpp"

mkdir -p "$WORK_DIR"
if [[ ! -d "$SRC/.git" ]]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$LLAMA_REPO"
fi
git -C "$SRC" fetch -q --depth 1 origin "$LLAMA_COMMIT"
git -C "$SRC" checkout -q --force "$LLAMA_COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$LLAMA_COMMIT" ]] || { echo "commit mismatch" >&2; exit 1; }

# Derive a trimmed copy of the upstream script (arm64 only, no mtmd, our deployment targets).
SCRIPT="$SRC/build-xcframework.local.sh"
perl -ne '
  s/^IOS_MIN_OS_VERSION=.*/IOS_MIN_OS_VERSION='"$IOS_MIN"'/;
  s/^MACOS_MIN_OS_VERSION=.*/MACOS_MIN_OS_VERSION='"$MACOS_MIN"'/;
  s/^LLAMA_BUILD_MTMD=.*/LLAMA_BUILD_MTMD=OFF/;
  s/archs="arm64 x86_64"/archs="arm64"/;
  s/CMAKE_OSX_ARCHITECTURES="arm64;x86_64"/CMAKE_OSX_ARCHITECTURES="arm64"/;
  next if /tools\/mtmd\/(mtmd|mtmd-helper)\.h/ || /libmtmd\.a/;
  s/^(\s*)(-DLLAMA_BUILD_MTMD=\$\{LLAMA_BUILD_MTMD\})/$1$2\n$1-DLLAMA_CURL=OFF/;
  print;
' "$SRC/build-xcframework.sh" > "$SCRIPT"
chmod +x "$SCRIPT"
if grep -E 'archs="arm64 x86_64"|ARCHITECTURES="arm64;x86_64"|libmtmd\.a|tools/mtmd/mtmd' "$SCRIPT"; then
    echo "patching of build script failed" >&2; exit 1
fi

# Keep build-machine paths (from __FILE__ in asserts) out of the binaries: they'd name this Mac's folders.
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$SRC/= -ffile-prefix-map=$HOME/="
export CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$SRC/= -ffile-prefix-map=$HOME/="
( cd "$SRC" && ./build-xcframework.local.sh macos ios-device ios-sim )
if find "$SRC/build-apple/llama.xcframework" -type f -name llama -exec strings -a {} + | grep -q -e "$SRC" -e "$HOME/"; then
    echo "built llama still holds local paths; check that CFLAGS reach the CMake build" >&2; exit 1
fi

rm -rf "$OUT"
cp -R "$SRC/build-apple/llama.xcframework" "$OUT"
echo "Built $OUT (llama.cpp $LLAMA_TAG @ $LLAMA_COMMIT)"
du -sh "$OUT"/*/ 
