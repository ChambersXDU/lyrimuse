# Lyrimuse package

This directory contains the Swift package for the native Apple Music lyrics app.

```sh
./build.sh --no-restart
swift run lyrimuse-selftest
```

`Sources/LyrimuseCore` contains lyric parsing, matching, providers, synchronization, cache access, and playback support. `Sources/lyrimuse` contains the macOS app. The cache is stored at `~/.config/lyrimuse/lyrimuse-enrich-cache.json`; its JSON schema is intentionally stable.

For an installed release, use `./build.sh`; use `./package.sh` to produce release archives. The app requires macOS 14+ and Apple Music Automation permission.
