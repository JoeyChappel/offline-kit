#!/bin/zsh
cd "${CORES:?Set CORES to the folder holding the cloned core repositories and work/ (see ../README.md)}/libretro-fceumm"
W=$(cd ..; pwd)/work
export FL=$(cat $W/fceumm/flags.txt)
for S in macos ios iossim; do
 case $S in
  macos) export TFLAGS="-target arm64-apple-macos14.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)"; IN=Versions/A/;;
  ios) export TFLAGS="-target arm64-apple-ios17.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"; IN=;;
  iossim) export TFLAGS="-target arm64-apple-ios17.0-simulator -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path)"; IN=;;
 esac
 O=$W/fceumm/$S; rm -rf $O; mkdir -p $O
 grep . $W/fceumm/srcs.txt | xargs -P8 -n1 -I{} $W/cc1.sh {} $O 2>&1 | head -20
 xcrun clang ${=TFLAGS} -dynamiclib -O3 -Wl,-dead_strip -Wl,-exported_symbols_list,$W/exports.txt -Wl,-install_name,@rpath/fceumm_libretro.framework/${IN}fceumm_libretro -o $O/fceumm_libretro.dylib $O/*.o -lm || echo LINKFAIL $S
done
