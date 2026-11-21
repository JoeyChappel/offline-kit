# Third-party software and content

The license texts these components require are in `Resources/Licenses`, and the app carries them, along with this file, inside its Resources folder.

Offline Kit is licensed under the GNU General Public License, version 3 (see `LICENSE`). It includes the software below. For each one, this lists the version Offline Kit is built from and where its complete source is published.

The source for each Offline Kit release is attached to that release on GitHub (`OfflineKit-<version>-source.zip`) at https://github.com/JoeyChappel/offline-kit/releases, beside the disk image.

## Linked into the app

| Component | Version | License | Source |
|---|---|---|---|
| llama.cpp | v1.0.0-b12359-b1b770d | MIT | https://github.com/ggml-org/llama.cpp (built by `Vendor/build-llama.sh`) |

Kiwix's prebuilt CoreKiwix.xcframework (libkiwix 14.2.1-2, from https://download.kiwix.org/release/libkiwix/, fetched by `Vendor/fetch-corekiwix.sh`) bundles these libraries. Kiwix builds them with its kiwix-build scripts: https://github.com/kiwix/kiwix-build.

| Library | Version | License | Source |
|---|---|---|---|
| libkiwix | 14.2.1 | GPLv3 or later | https://github.com/kiwix/libkiwix |
| libzim | bundled with libkiwix 14.2.1 | GPLv2 or later | https://github.com/openzim/libzim |
| Xapian | 1.4.23 | GPLv2 or later | https://xapian.org |
| ICU | 73.2 | Unicode license (with third-party notices) | https://github.com/unicode-org/icu |
| libcurl | 8.4.0 | curl license (MIT-style) | https://curl.se |
| libmicrohttpd | 0.9.76 | LGPL 2.1 or later | https://www.gnu.org/software/libmicrohttpd/ |
| pugixml | 1.15 | MIT | https://pugixml.org |
| Mustache (kainjow) | 4.1 | Boost Software License 1.0 | https://github.com/kainjow/Mustache |
| zlib | 1.3.1 | zlib license | https://zlib.net |
| Zstandard | bundled | BSD | https://github.com/facebook/zstd |
| liblzma (XZ Utils) | 5.2.6 | public domain | https://tukaani.org/xz/ |

## Game cores (loaded at runtime from `Vendor/Cores`)

Built by the scripts in `Vendor/Cores/scripts`. Each core's license text is beside it in `Vendor/Cores`, and the app carries the same texts in `Resources/Licenses`. The libraries the cores compile in (FreeType, libpng, libjpeg, the Xiph codecs, giflib, FriBidi, FluidLite, libmad, libmpeg2, FAAD2, zlib, libchdr, LZMA SDK, Zstandard, Munt and libretro-common) are listed with their notices in `Resources/Licenses/Game engine libraries.txt`.

| Core | Systems | License | Source commit |
|---|---|---|---|
| mGBA | Game Boy, Game Boy Color, Game Boy Advance | MPL 2.0 | https://github.com/libretro/mgba at 7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6 |
| FCEUmm | NES | GPLv2 or later | https://github.com/libretro/libretro-fceumm at 77468e568d9fe9c48d684ca911f1a3fe7259fdf7 |
| Beetle PCE Fast (Mednafen) | PC Engine / TurboGrafx-16 | GPLv2 or later | https://github.com/libretro/beetle-pce-fast-libretro at 4cf066e22533186d0cfad85a0fec2aced93e4e29 |
| DOSBox Pure | DOS | GPLv2 or later | https://github.com/libretro/dosbox-pure at e39497e7c2a32c67c26e6598dd14f6d58c384bfd (1.0-preview8) |
| ScummVM | ScummVM adventure games | GPLv3, plus its bundled libraries' licenses | https://github.com/libretro/scummvm at e0ddc60bfabb1efdf1e135006c8914ca59d0596c, with libretro-deps at bab7d258c451c0e7cba4b6a79f1b062c13efff38 and libretro-common at 879c8d507b0b52e77e27d759239c2b5df1e26dfd |

`Vendor/Cores/libretro.h` is the libretro API header (MIT), compiled into the app itself through `Sources/Bridge`.

## Content

- **Starter books** (`Resources/StarterBooks`): public-domain EPUBs from Standard Ebooks, dedicated to the public domain under CC0 1.0.
- **Library downloads** come from Kiwix (Wikipedia, WikiMed, iFixit, Stack Exchange and more), LibriVox, OpenStreetMap and Open Food Facts. They aren't part of this repository. Licenses vary by source; Wikipedia and Stack Exchange use CC BY-SA, and Open Food Facts uses the Open Database License.

Kiwix, Wikipedia, LibriVox, OpenStreetMap and Open Food Facts are not affiliated with Offline Kit.
