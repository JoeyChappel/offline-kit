#!/bin/zsh
cd "${CORES:?Set CORES to the folder holding the cloned core repositories and work/ (see ../README.md)}"; W=$PWD/work
for S in ${=ONLY:-macos ios iossim}; do
 case $S in
  macos) A=(-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0); IN=Versions/A/;;
  ios) A=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0); IN=;;
  iossim) A=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0); IN=;;
 esac
 cmake -S mgba -B $W/mgba-$S -G "Unix Makefiles" $A -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-O3 -fvisibility=hidden" "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-exported_symbols_list,$W/exports.txt -Wl,-install_name,@rpath/mgba_libretro.framework/${IN}mgba_libretro -Wl,-dead_strip -mmacosx-version-min=14.0" \
  -DBUILD_LIBRETRO=ON -DSKIP_LIBRARY=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DUSE_EPOXY=OFF -DUSE_FFMPEG=OFF -DUSE_PNG=OFF -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DENABLE_SCRIPTING=OFF -DUSE_EDITLINE=OFF -DUSE_DISCORD_RPC=OFF -DENABLE_DEBUGGERS=OFF -DENABLE_GDB_STUB=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF -DBUILD_CINEMA=OFF -DBUILD_STATIC=OFF -DBUILD_SHARED=OFF -DUSE_JSON_C=OFF -DUSE_FREETYPE=OFF -DUSE_LZMA=OFF -DUSE_ZLIB=ON -DBUILD_PERF=OFF -DBUILD_HEADLESS=OFF -DBUILD_EXAMPLE=OFF > $W/cfg-$S.log 2>&1 || { echo CFGFAIL $S; tail -20 $W/cfg-$S.log; continue; }
 cmake --build $W/mgba-$S -j8 > $W/build-$S.log 2>&1 || { echo BUILDFAIL $S; grep -n "error" $W/build-$S.log | head; }
done
