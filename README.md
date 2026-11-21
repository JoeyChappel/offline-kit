# Offline Kit

A family reference library for the Mac that works with no internet. Ask questions and get answers from your saved library with sources, read Wikipedia, medical references and repair guides, keep a family emergency plan, and enjoy your own movies, music, audiobooks, books and games.

**Download:** https://joeychappel.com/offline-kit/ (Mac with Apple silicon, macOS 26 or later)

Offline Kit is free. If it helps your family, you can [buy me a coffee](https://buymeacoffee.com/joeychappel).

## What's in this repository

The complete source of the Mac app, plus the iPhone/iPad and Apple TV apps that share most of its code:

- `Sources/` the app: `Core` (library, search, answers, downloads), `App` (shared SwiftUI), `Mac`, `iOS`, `TV`, and `Bridge` (Objective-C++ wrappers for libzim and the libretro game cores)
- `Resources/` icons, artwork and the public-domain starter books
- `Vendor/` scripts that fetch or build the third-party libraries, and the prebuilt game cores with their build scripts
- `Tools/` the `okit` command-line test harness, checks, and the release scripts
- `web/` the download page

`DEVELOPMENT.md` has detailed notes on how each part works and how it was tested.

## Building

Requirements: Xcode 27 and XcodeGen (`brew install xcodegen`).

```bash
Vendor/fetch-corekiwix.sh
Vendor/build-llama.sh
xcodegen generate
xcodebuild -project OfflineKit.xcodeproj -scheme OfflineKit-macOS -derivedDataPath build build
```

`fetch-corekiwix.sh` downloads Kiwix's prebuilt CoreKiwix.xcframework (libkiwix and libzim). `build-llama.sh` builds llama.cpp for the built-in answer model. The game cores are already in `Vendor/Cores`; `Vendor/Cores/README.md` explains how to rebuild them from source.

Release builds are signed with a Developer ID and notarized by `Tools/Release/make-release.sh`; you'll need your own signing identity to make one.

## License

Offline Kit is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See `LICENSE` for the full text.

Copyright © 2026 Joey Chappel.

Offline Kit includes and links to third-party software under their own licenses, listed with where to get each one's source in `THIRD-PARTY-NOTICES.md`.

Answers come from your offline library where it covers the question, and anything else is labeled “Not from the library.” They can still be wrong. Double-check anything medical, electrical or safety-related against the cited article, and get professional help when you can.
