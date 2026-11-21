# Offline Kit site

Download page for Offline Kit, published at https://joeychappel.com/offline-kit/.

This folder is the source of truth. Edit here, then copy it into the site repo:

```bash
rsync -a --delete --exclude README.md web/ ../../joeychappel/offline-kit/
```

Commit and push the site repo, then pull and deploy in cPanel.

## Download link

Both buttons point at `https://github.com/JoeyChappel/offline-kit/releases/latest/download/OfflineKit.dmg`, which always serves the newest release from `Tools/Release/publish-release.sh`. The page names no version number, so it never goes stale.

## Art

- `img/icon.png` is the app icon (`Resources/Assets.xcassets/AppIcon.appiconset/ios-1024.png`) at 256 px.
- `img/forest.jpg` is the app's own `Resources/watch-forest.jpg` at 1800 px.
- `img/books.jpg`, `img/resources.jpg` and `img/plan.jpg` are window snapshots of a Debug build in a test home (`OFFLINEKIT_HOME`, `-seedHousehold YES`, `-snapshot`), cropped to the content area and resized to 1600 px. The household in `plan.jpg` is the made-up sample data. Never use a snapshot of a real kit: it shows real household details and disk space.

Keep claims to what the app does today.
