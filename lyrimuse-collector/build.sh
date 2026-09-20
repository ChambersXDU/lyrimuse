#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
BIN="../bin/collector"
BUNDLED_BIN="/Applications/Lyrimuse.app/Contents/Resources/collector"
LABEL="com.lyrimuse.collector"
TOOLCHAIN=go1.24.4

COLLECTOR_VERSION="${LYRIMUSE_VERSION:-}"
if [ -z "$COLLECTOR_VERSION" ] && [ -f "$BUNDLED_BIN" ]; then
  COLLECTOR_VERSION="$(plutil -extract CFBundleShortVersionString raw \
    /Applications/Lyrimuse.app/Contents/Info.plist 2>/dev/null || true)"
fi
[ -z "$COLLECTOR_VERSION" ] && COLLECTOR_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "$COLLECTOR_VERSION" ] && COLLECTOR_VERSION="dev"

echo "==> building with $TOOLCHAIN (native LC_UUID + valid signature), version $COLLECTOR_VERSION"
GOTOOLCHAIN="$TOOLCHAIN" go build -ldflags "-X main.clientVersion=$COLLECTOR_VERSION" -o "$BIN" .
codesign -v "$BIN" && echo "    signature valid"

RUNTIME_BIN="$BIN"
if [ -d /Applications/Lyrimuse.app ]; then
  cp "$BIN" "$BUNDLED_BIN"
  codesign -v "$BUNDLED_BIN" && echo "    bundled copy signature valid"
  RUNTIME_BIN="$BUNDLED_BIN"
fi

if [ "${1:-}" = "--no-restart" ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

echo "==> restarting via launchd"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3
if ! pgrep -f "$RUNTIME_BIN" >/dev/null 2>&1; then
  echo "==> kickstart produced no running process, retrying via bootout+bootstrap"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  sleep 1
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  sleep 2
fi
if pid=$(pgrep -f "$RUNTIME_BIN"); then
  echo "==> collector running, pid $pid"
else
  echo "!! collector not running — see ~/Library/Logs/lyrimuse.log" >&2
  exit 1
fi
