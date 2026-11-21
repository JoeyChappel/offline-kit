# Forest installer artwork

Forest A is the approved main installer design. The light Field Guide B remains a design alternative; the main DMG has one fixed forest background and does not automatically switch with system appearance.

The background contains only the photograph, headings, drag arrow, and footer. The app, Applications shortcut, and Start Here PDF are actual Finder items, placed by `build-dmg.py`. No painted buttons or duplicate icons are used.

- Window content: 720×560 logical points.
- `forest-install.png`: 720×560 at 72 dpi. One resolution only: Finder on macOS 26 shows a two-resolution (Retina) TIFF background zoomed to twice its size.
- The window is 720×592 so the 32-point title bar doesn't cut off the artwork.
- Finder draws icon labels in black over a background picture, in Dark mode too, so the art has a light plate behind each label (centers at y 300 for the top row, 470 for the guide).
- App and Applications centers: (180,225) and (540,225).
- Guide center: (360,395).
- Native Finder icon size: 112; labels: 14.

Regenerate artwork from the existing forest asset with:

```sh
swift Tools/Release/render-installer.swift .
```

`make-release.sh` uses the pinned, isolated Python toolchain from `requirements-dmg.txt` to write the Finder layout and background. It does not automate Finder or change the user's preferences. `DMG_PYTHON` can select an existing compatible Python environment.

Checked in Finder on macOS 26 (Dark mode): background at the right scale, headings and footer visible, all three labels readable on their plates.
