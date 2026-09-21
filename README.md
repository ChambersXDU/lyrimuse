# Lyrimuse

Native macOS menu-bar and desktop lyrics for Apple Music. It follows playback with LRC/YRC word timing, translation, romanization, duet lines, cover art, and a Lyrics Manager for editing, deleting, and re-matching cached songs.

The app queries five lyric providers (LRCLIB, Kuwo, NetEase, Kugou, and QQ Music), scores their candidates, and stores the result in `~/.config/lyrimuse/lyrimuse-enrich-cache.json`. Cached lyrics work offline. The cache file format is kept stable across releases.

Apple Music control and playback position use macOS Automation permission. The app also provides a desktop overlay, menu-bar lyrics, offset correction, pinning, Settings Search, configuration import/export, backups, shortcuts, and optional listening integrations.

## Install

```sh
brew tap yudaotor/lyrimuse
brew install --cask lyrimuse
```

Or download the latest release from GitHub. macOS 14 or newer is required.

## Build and test

```sh
cd lyrimuse
./build.sh --no-restart
swift run lyrimuse-selftest
```

Use `./build.sh --universal` for an arm64 + Intel build and `./package.sh` for release assets.

## License

GPL-3.0. Lyrics, artwork, and metadata remain the property of their respective rights holders; the app caches them locally for personal display.
