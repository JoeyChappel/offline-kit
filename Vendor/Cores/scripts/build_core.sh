#!/bin/zsh
# usage: build_core.sh <name> <source dir> <work subdir>   env: ONLY (platforms), PAR (jobs), CXXSTD (see cc2.sh), LIBS (extra link flags)
# Compiles the core's source lists (cxx.txt / c.txt, dumped from its makefile) for each Apple platform and links a dylib.
N=$1; SRC=$2; WS=$3; HERE=${0:A:h}
cd $SRC
export DEFS="$(cat $WS/defs.txt)"
for P in ${=ONLY:-macos ios iossim}; do
 case $P in
  macos) export T="-target arm64-apple-macos26.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)"; IN=Versions/A/;;
  ios) export T="-target arm64-apple-ios26.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"; IN=;;
  iossim) export T="-target arm64-apple-ios26.0-simulator -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path)"; IN=;;
 esac
 export O=$WS/$P; rm -rf $O; mkdir -p $O
 cat $WS/cxx.txt $WS/c.txt 2>/dev/null | grep . | xargs -P${PAR:-8} -I{} $HERE/cc2.sh {} 2>&1 | grep -E "FAIL|error:" | head -20
 xcrun clang++ ${=T} -dynamiclib -O3 -stdlib=libc++ -Wl,-dead_strip -Wl,-exported_symbols_list,$HERE/exports.txt -Wl,-install_name,@rpath/$N.framework/${IN}$N -o $O/$N.dylib $O/*.o -lm ${=LIBS} || echo "LINKFAIL $P"
 ls -la $O/$N.dylib 2>/dev/null | awk '{print "'$P'", $5}'
done
