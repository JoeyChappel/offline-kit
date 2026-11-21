# Offline Kit site

Download page for Offline Kit, published at https://joeychappel.com/offline-kit/.

This folder is the source of truth. Edit here, then copy it into the site repo:

```bash
rsync -a --delete --exclude README.md web/ ../../joeychappel/offline-kit/
```

Commit and push the site repo, then pull and deploy in cPanel.

## Design and local preview

The Forest Studio layout uses the existing forest art and app icon, real Get Resources/Prepare screenshots in the hero, open feature columns and setup steps, and two Buy Me a Coffee buttons. It also includes a Books preview, an accessible native FAQ, and a responsive menu. Typography uses local system fonts; no build tools, external fonts or JavaScript dependencies are required.

Styles live in `styles.css`. Keep that file with `index.html` when copying or publishing the site. Every visual asset is local to `img/`.

Preview from this repository with:

```bash
python3 -m http.server 8791 --bind 127.0.0.1 --directory OfflineKitApp/web
```

Checked in the browser at 360, 390, 768 and 1440 px: no horizontal overflow; phone/tablet menu navigation works and closes on selection; FAQ expansion works; images load; no console errors. Download and support destinations, section anchors and local asset references are verified. Screenshots use fictional household data.

This revision is built in the source folder. It has not been copied into the separate site repository or deployed to cPanel. The deployable ZIP contains `index.html`, `styles.css`, and `img/`, with no containing directory.

## Download link

The download links point at `https://github.com/JoeyChappel/offline-kit/releases/latest/download/OfflineKit.dmg`, which always serves the newest release from `Tools/Release/publish-release.sh`. The page names no version number, so it never goes stale.

## Art

- `img/icon.png` is the app icon (`Resources/Assets.xcassets/AppIcon.appiconset/ios-1024.png`) at 256 px.
- `img/forest.jpg` is the app's own `Resources/watch-forest.jpg` at 1800 px.
- `img/books.jpg`, `img/resources.jpg` and `img/plan.jpg` are window snapshots of a Debug build in a test home (`OFFLINEKIT_HOME`, `-seedHousehold YES`, `-snapshot`), cropped to the content area and resized to 1600 px. The household in `plan.jpg` is the made-up sample data. Never use a snapshot of a real kit: it shows real household details and disk space.

Keep claims to what the app does today.
