# Emulator cores

Prebuilt libretro cores as dynamic xcframeworks (macOS arm64, iOS arm64, iOS simulator arm64; none for tvOS yet), loaded with `dlopen` by `Sources/Bridge/RetroCore`.

| Core | Systems | License | Source commit |
|---|---|---|---|
| mgba_libretro | Game Boy, GBC, GBA | MPL 2.0 (`LICENSE-mgba.txt`) | github.com/libretro/mgba @ 7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6 |
| fceumm_libretro | NES | GPLv2 or later (`LICENSE-fceumm.txt`) | github.com/libretro/libretro-fceumm @ 77468e568d9fe9c48d684ca911f1a3fe7259fdf7 |
| mednafen_pce_fast_libretro | PC Engine / TurboGrafx-16 (HuCards) | GPLv2 or later (`LICENSE-pce-fast.txt`) | github.com/libretro/beetle-pce-fast-libretro @ 4cf066e22533186d0cfad85a0fec2aced93e4e29 |
| dosbox_pure_libretro | DOS games and programs | GPLv2 or later (`LICENSE-dosbox-pure.txt`) | github.com/libretro/dosbox-pure @ e39497e7c2a32c67c26e6598dd14f6d58c384bfd (1.0-preview8) |
| scummvm_libretro | ScummVM point-and-click adventures | GPLv3, plus bundled libraries' licenses (`LICENSE-scummvm.txt`) | github.com/libretro/scummvm @ e0ddc60bfabb1efdf1e135006c8914ca59d0596c (backends/platform/libretro; deps: libretro-deps @ bab7d258c451c0e7cba4b6a79f1b062c13efff38, libretro-common @ 879c8d507b0b52e77e27d759239c2b5df1e26dfd) |

`scripts/` holds the scripts that built them. The FCEUmm build's own flag and source lists (`work/fceumm/flags.txt`, `srcs.txt`) weren't kept; they come from that core's `Makefile.libretro` for `platform=osx` the same way `dumpvars` produces them for the other cores. They run from a scratch folder holding the cloned core repositories beside a `work/` folder: set `CORES` to that folder (for example `CORES=~/cores scripts/build_mgba.sh`). The packaging scripts write into this folder. Order: `build_mgba.sh`, `build_fceumm.sh`, then `package.sh`.

Video formats: mGBA outputs RGB565, FCEUmm XRGB8888. FCEUmm needs a real file path (`need_fullpath`).

PCE Fast (added later) uses `scripts/build_core.sh`, which compiles each core's own source lists for macOS 26 / iOS 26. Steps: run `make -f Makefile -f scripts/vars.mk dumpvars platform=osx OUT=<dir>` in the core's makefile folder to write `cxx.txt` / `c.txt`, put that core's `-D`/`-I` flags in `<dir>/defs.txt` (saved copies in `scripts/flags/`), run `build_core.sh <framework name> <makefile folder> <dir>`, then `package2.sh`. PCE Fast needs `-Dfdopen=fdopen` for its bundled zlib on the current SDK.

Formats: PCE Fast plays `.pce` HuCards with no BIOS; CD games need a system card BIOS and aren't offered. It outputs RGB565 and needs a real file path.

The Stella core (Atari 2600) was removed in 0.2.5: its source names no GPL version and ships only GPLv2 text, so it couldn't be confirmed compatible with the app's GPLv3.

## DOSBox Pure and ScummVM

Both are built with `build_core.sh` like PCE Fast, then packaged with `package_core.sh` (package2.sh generalized to one core per call, with an optional resources folder). `build_core.sh` now also takes `PAR` (parallel jobs), `CXXSTD` (passed to `cc2.sh`, default `-std=c++23 -fno-rtti`) and `LIBS`; `exports.txt` (exported `retro_*` symbols) lives in `scripts/` beside it.

**DOSBox Pure.** The makefile globs its sources, so list them directly: `ls *.cpp src/*.cpp src/*/*.cpp src/*/*/*.cpp > <dir>/cxx.txt`. Flags are in `flags/dosbox-defs.txt`; build with `CXXSTD=-std=gnu++11`. `-DDISABLE_DYNAREC=1` turns off its recompiler, so the core needs no JIT entitlement under the hardened runtime. It carries its own zip reader (no libz). Package: `package_core.sh <dir> dosbox_pure_libretro 1.0-preview8 dosbox`.

**ScummVM.** In `backends/platform/libretro`, `make -f Makefile -f scripts/vars.mk dumpobjs platform=osx LITE=1 BUILD_64BIT=1 USE_LIBCO=0 OUT=<dir>` writes `objs.txt` (object files, including every engine module) and `defines.txt`; the makefile also clones its pinned `libretro-deps` and `libretro-common` into `deps/`. `objs_to_sources.sh . <scummvm root> <dir>` maps the objects back to `cxx.txt` / `c.txt`. Before dumping, add four engines to the lite build so the freeware games they run are included: `printf '%s\n' dreamweb cge cge2 griffon >> backends/platform/libretro/lite_engines.list` (run from the ScummVM root). Build with `CXXSTD=-std=c++11` from that folder, using `flags/scummvm-defs.txt` (paths relative to it; `<work>/compat` holds `flags/compat/fp.h`). Changes from the dumped flags, all for the 26 SDK:
- `-idirafter` instead of `-I` for `deps/libretro-deps/libmad`, whose file named `version` hides the C++ `<version>` header.
- `flags/compat/fp.h` (just `#include <math.h>`): libpng asks for the classic Mac `fp.h` because the SDK now defines `TARGET_OS_MAC`.
- `-DFT_CONFIG_OPTION_SYSTEM_ZLIB`: FreeType's private zlib copy clashes with MacTypes; this uses the bundled libz instead.
- `USE_LIBCO=0` (real threads, 2 MB stack via `-DHAVE_THREAD_ATTR -DHAVE_THREADS`): libco's arm64 switch doesn't save the floating-point registers.

ScummVM has no OpenGL here; the app answers its `scummvm_video_hw_acceleration` option with `disabled`, without which the core asks for a GPU frame. Engine data files for the included engines (`sky.cpt`, `queen.tbl`, `lure.dat`, `drascula.dat`, `teenagent.dat`, `mort.dat`, `kyra.dat`, `encoding.dat`) and `vkeybd_default.zip`, all from the same ScummVM tree (`dists/engine-data`, `backends/vkeybd/packs`), are packaged in each framework's `extra` folder: `package_core.sh <dir> scummvm_libretro 2026.4.1 scummvm <res>` with `<res>/extra/` holding them. The app writes that location into ScummVM's `scummvm.ini` at each launch.

**In the app.** DOS: a `.dosz` file anywhere (DOSBox Pure's name for a zipped game), or a `.zip`, `.exe`, `.com`, `.bat` or disk image directly inside a `Games/DOS` folder; Add Games puts a `.zip` there only if it lists a DOS program. ScummVM: each folder inside `Games/ScummVM` (ScummVM detects the game), or a `.scummvm` file holding a game ID. Both take the keyboard (libretro keyboard callback, plus `RETRO_DEVICE_KEYBOARD` state) and mouse; on iPhone and iPad, taps on the picture are the libretro pointer (ScummVM: tap to click, hold to right-click; DOSBox Pure: touchpad mode).

**Freeware for testing or bundling.** Beneath a Steel Sky (`BASS-Floppy-1.3.zip`) and Flight of the Amazon Queen (`FOTAQ_Floppy.zip`) from downloads.scummvm.org both played. Their readme licenses allow free redistribution on any medium, including in a larger distribution, as long as the readme and copyright notices stay with the game and no fee is charged for the game itself, so they can be bundled like the starter books (keep each `readme.txt`). ScummVM's site lists more freeware (Lure of the Temptress, Drascula, Dreamweb, Soltys, Teen Agent); check each readme before bundling. No DOS game was downloaded; DOSBox Pure was tested with a small input-test program built for the purpose.
