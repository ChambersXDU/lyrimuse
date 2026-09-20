#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NO_RESTART=0
UNIVERSAL=0
DEST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-restart) NO_RESTART=1 ;;
    --universal) UNIVERSAL=1 ;;
    --dest)
      shift
      DEST="${1:-}"
      [ -n "$DEST" ] || { echo "!! --dest 需要一个路径" >&2; exit 2; }
      ;;
    *) echo "!! 未知参数:$1(可用:--universal / --no-restart / --dest <路径>)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$UNIVERSAL" = 1 ]; then
  ARCHES="arm64 x86_64"
else
  ARCHES="$(uname -m)"
fi

DEV_SIGN_NAME="Lyrimuse Dev Signing"
SIGN_ID="${LYRIMUSE_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_SIGN_NAME"; then
    SIGN_ID="$DEV_SIGN_NAME"
  else
    SIGN_ID="-"
  fi
fi
if [ "$SIGN_ID" = "-" ]; then
  echo "==> codesign identity: ad-hoc(授权会在每次重装后失效,见脚本里这一段注释)"
else
  echo "==> codesign identity: $SIGN_ID"
fi
[ -n "$DEST" ] && NO_RESTART=1
merge_slices() {
  local out="$1"; shift
  if [ "$#" -eq 1 ]; then cp "$1" "$out"; else lipo -create "$@" -output "$out"; fi
}

APP_NAME="Lyrimuse"
LABEL="me.yudaotor.lyrimuse"
COLLECTOR_LABEL="com.lyrimuse.collector"
LOG_FILE="$HOME/Library/Logs/lyrimuse.log"
APP_VERSION="${LYRIMUSE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
[ -z "$APP_VERSION" ] && APP_VERSION="0.0.0"
BUILD_VERSION="$(./scripts/build-version.sh "$APP_VERSION")" || {
  echo "!! 版本号形态不合法: $APP_VERSION(要 X.Y.Z 或 X.Y.Z-alpha|beta|rc.N,见 scripts/build-version.sh)" >&2
  exit 1
}
FINAL_APP_DIR="${DEST:-/Applications/${APP_NAME}.app}"
if [ -n "$DEST" ]; then
  APP_DIR="$FINAL_APP_DIR"
  STAGE=""
else
  for stale in "$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage."*; do
    [ -e "$stale" ] && rm -rf "$stale"
  done
  STAGE="$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage.$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  trap 'rm -rf "$STAGE"' EXIT
  APP_DIR="$STAGE"
fi
BIN="$APP_DIR/Contents/MacOS/lyrimuse"
FAT_DIR="$(mktemp -d)"

echo "==> building (release) [$ARCHES]"
SWIFT_SLICES=()
TRANSLATE_SLICES=()
ROMANIZE_SLICES=()
SPM_PATH_ARGS=()
[ -n "${LYRIMUSE_SPM_CACHE_PATH:-}" ] && SPM_PATH_ARGS+=(--cache-path "$LYRIMUSE_SPM_CACHE_PATH")
[ -n "${LYRIMUSE_SPM_SCRATCH_PATH:-}" ] && SPM_PATH_ARGS+=(--scratch-path "$LYRIMUSE_SPM_SCRATCH_PATH")
for arch in $ARCHES; do
  swift build -c release --arch "$arch" ${SPM_PATH_ARGS[@]+"${SPM_PATH_ARGS[@]}"}
  BIN_PATH="$(swift build -c release --arch "$arch" ${SPM_PATH_ARGS[@]+"${SPM_PATH_ARGS[@]}"} --show-bin-path)"
  SWIFT_SLICES+=("$BIN_PATH/lyrimuse")
  TRANSLATE_SLICES+=("$BIN_PATH/lyrics-translate")
  ROMANIZE_SLICES+=("$BIN_PATH/lyrics-romanize")
done
merge_slices "$FAT_DIR/lyrimuse" "${SWIFT_SLICES[@]}"
merge_slices "$FAT_DIR/lyrics-translate" "${TRANSLATE_SLICES[@]}"
merge_slices "$FAT_DIR/lyrics-romanize" "${ROMANIZE_SLICES[@]}"

echo "==> building collector [$ARCHES]"
COLLECTOR_SLICES=()
for arch in $ARCHES; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "!! 不认识的架构:$arch" >&2; exit 2 ;;
  esac
  out="$FAT_DIR/collector-$arch"
  (cd ../lyrimuse-collector && GOTOOLCHAIN="${LYRIMUSE_GOTOOLCHAIN:-go1.24.4}" GOOS=darwin GOARCH="$goarch" \
    go build -ldflags "-X main.clientVersion=$APP_VERSION" -o "$out" .)
  COLLECTOR_SLICES+=("$out")
done
merge_slices "$FAT_DIR/collector" "${COLLECTOR_SLICES[@]}"

echo "==> assembling .app bundle"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$FAT_DIR/lyrimuse" "$BIN"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -f "$APP_DIR/Contents/Resources/collector"
cp "$FAT_DIR/collector" "$APP_DIR/Contents/Resources/collector"
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/collector"

rm -f "$APP_DIR/Contents/Resources/lyrics-translate"
cp "$FAT_DIR/lyrics-translate" "$APP_DIR/Contents/Resources/lyrics-translate"
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/lyrics-translate"

rm -f "$APP_DIR/Contents/Resources/lyrics-romanize"
cp "$FAT_DIR/lyrics-romanize" "$APP_DIR/Contents/Resources/lyrics-romanize"
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/lyrics-romanize"

if [ -n "${LYRIMUSE_MEDIA_CONTROL_PREFIX:-}" ]; then
  MEDIA_CONTROL_PREFIX="$LYRIMUSE_MEDIA_CONTROL_PREFIX"
else
  MEDIA_CONTROL_PREFIX="$(brew --prefix media-control 2>/dev/null)"
  if [ ! -x "$MEDIA_CONTROL_PREFIX/bin/media-control" ] && command -v brew >/dev/null 2>&1; then
    echo "==> media-control not found, installing via Homebrew (QQ 音乐支持)"
    brew install media-control || echo "!! brew install media-control 失败——继续构建,QQ 音乐支持这次不可用,Apple Music 不受影响" >&2
    MEDIA_CONTROL_PREFIX="$(brew --prefix media-control 2>/dev/null)"
  fi
fi
if [ -x "$MEDIA_CONTROL_PREFIX/bin/media-control" ]; then
  rm -rf "$APP_DIR/Contents/Resources/media-control"
  mkdir -p "$APP_DIR/Contents/Resources/media-control/bin" \
           "$APP_DIR/Contents/Resources/media-control/lib" \
           "$APP_DIR/Contents/Resources/media-control/Frameworks"
  cp "$MEDIA_CONTROL_PREFIX/bin/media-control" "$APP_DIR/Contents/Resources/media-control/bin/"
  cp -R "$MEDIA_CONTROL_PREFIX/lib/media-control" "$APP_DIR/Contents/Resources/media-control/lib/media-control"
  MC_FW_SRC="$MEDIA_CONTROL_PREFIX/Frameworks/MediaRemoteAdapter.framework"
  [ -d "$MC_FW_SRC" ] || MC_FW_SRC="$MEDIA_CONTROL_PREFIX/Library/Frameworks/MediaRemoteAdapter.framework"
  ditto "$MC_FW_SRC" "$APP_DIR/Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework"
  chmod -R u+w "$APP_DIR/Contents/Resources/media-control"
  /usr/bin/sed -i '' "s|'\.\.', 'Library', 'Frameworks', 'MediaRemoteAdapter.framework'|'..', 'Frameworks', 'MediaRemoteAdapter.framework'|" \
    "$APP_DIR/Contents/Resources/media-control/bin/media-control"
  codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/media-control/bin/media-control"
  if [ "$UNIVERSAL" = 1 ]; then
    MC_FW="$APP_DIR/Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework"
    if [ -n "${LYRIMUSE_MEDIA_CONTROL_PREFIX:-}" ]; then
      MC_VER="$(basename "$MEDIA_CONTROL_PREFIX")"
    else
      MC_VER="$(brew list --versions media-control | awk '{print $2}')"
    fi
    MC_PIN_VER="0.7.6"
    MC_TAG="sonoma"
    MC_SHA="52a07ebec136e88574c620dfaa6cf2121d37aade09967bf4d6bab0d316ee6aac"
    if [ "$MC_VER" != "$MC_PIN_VER" ]; then
      echo "!! media-control 本机版本 $MC_VER 与钉住的 $MC_PIN_VER 不一致,跳过 lipo——x86_64 上 QQ 音乐支持不可用(重新钉版见本段注释)" >&2
    else
      MC_TGZ="$FAT_DIR/media-control-x86_64-$MC_PIN_VER.tar.gz"
      if curl -fsSL -H "Authorization: Bearer QQ==" \
           "https://ghcr.io/v2/homebrew/core/media-control/blobs/sha256:$MC_SHA" -o "$MC_TGZ" \
         && [ "$(shasum -a 256 "$MC_TGZ" | awk '{print $1}')" = "$MC_SHA" ]; then
        MC_X86="$FAT_DIR/media-control-x86_64"
        rm -rf "$MC_X86"; mkdir -p "$MC_X86"
        tar -xzf "$MC_TGZ" -C "$MC_X86"
        MC_X86_ROOT="$(find "$MC_X86" -type d -name "Frameworks" -maxdepth 3 | head -1)"
        MC_X86_ROOT="$(dirname "${MC_X86_ROOT:-$MC_X86}")"
        merged=0
        for rel in "Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
                   "lib/media-control/MediaRemoteAdapterTestClient"; do
          dst="$APP_DIR/Contents/Resources/media-control/$rel"
          src="$MC_X86_ROOT/$rel"
          if [ -f "$dst" ] && [ -f "$src" ]; then
            lipo -create "$dst" "$src" -output "$dst.fat" && mv "$dst.fat" "$dst"
            merged=$((merged + 1))
          fi
        done
        if [ "$merged" -gt 0 ]; then
          codesign --force --sign "$SIGN_ID" "$MC_FW"
          codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/media-control/lib/media-control/MediaRemoteAdapterTestClient" 2>/dev/null || true
          echo "    media-control x86_64 切片已合入($merged 个 Mach-O, bottle tag=$MC_TAG)"
        else
          echo "!! media-control x86_64 bottle 里没找到预期的 Mach-O,跳过 lipo" >&2
        fi
      else
        echo "!! media-control x86_64 bottle 下载或校验失败,跳过 lipo——x86_64 上 QQ 音乐支持不可用" >&2
      fi
    fi
  fi
  echo "    media-control bundled (QQ 音乐支持)"
else
  if [ -n "$STAGE" ] && [ -d "$FINAL_APP_DIR/Contents/Resources/media-control" ]; then
    ditto "$FINAL_APP_DIR/Contents/Resources/media-control" "$APP_DIR/Contents/Resources/media-control"
    echo "    media-control 从现装包继承(brew 里没找到,保持已装版本不被降级)"
  fi
  echo "!! media-control not found (brew install media-control) — QQ 音乐支持这次构建不可用,Apple Music 不受影响" >&2
fi

rm -rf "$APP_DIR/Contents/Resources/zh-hans.lproj" "$APP_DIR/Contents/Resources/zh-hant.lproj" "$APP_DIR/Contents/Resources/en.lproj"
cp -R Sources/lyrimuse/Resources/zh-hans.lproj "$APP_DIR/Contents/Resources/zh-hans.lproj"
cp -R Sources/lyrimuse/Resources/zh-hant.lproj "$APP_DIR/Contents/Resources/zh-hant.lproj"
cp -R Sources/lyrimuse/Resources/en.lproj "$APP_DIR/Contents/Resources/en.lproj"
for png in Sources/lyrimuse/Resources/*.png; do
  cp "$png" "$APP_DIR/Contents/Resources/$(basename "$png")"
done
cp ../THIRD_PARTY_LICENSES "$APP_DIR/Contents/Resources/THIRD_PARTY_LICENSES"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>lyrimuse</string>
    <key>CFBundleIdentifier</key>
    <string>${LABEL}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Legacy notification alert style preference to display action buttons. -->
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
    <!-- Explains purpose when prompting for Apple Events automation permission (Music/browsers). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Lyrimuse needs to send Apple Events to media players and browsers to read the currently playing track and show synced lyrics.</string>
</dict>
</plist>
PLIST

codesign -s "$SIGN_ID" --force --identifier "$LABEL" "$APP_DIR"
codesign -v "$APP_DIR" && echo "    signature valid"
codesign -v "$APP_DIR/Contents/Resources/collector" && echo "    collector signature valid"

echo "==> architecture check [$ARCHES]"
ARCH_BAD=""
while IFS= read -r f; do
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [ -z "$archs" ] && continue
  printf "    %-56s %s\n" "${f#$APP_DIR/}" "$archs"
  for want in $ARCHES; do
    case " $archs " in *" $want "*) ;; *) ARCH_BAD="$ARCH_BAD ${f#$APP_DIR/}(缺$want)" ;; esac
  done
  for got in $archs; do
    case " $ARCHES " in *" $got "*) ;; *) ARCH_BAD="$ARCH_BAD ${f#$APP_DIR/}(多余$got)" ;; esac
  done
done < <(find "$APP_DIR" -type f)
if [ -n "$ARCH_BAD" ]; then
  echo "!! 架构与目标[$ARCHES]不符:" >&2
  for f in $ARCH_BAD; do echo "     $f" >&2; done
  echo "!! 要发布的构建先解决上面这些(package.sh 会硬拦)" >&2
fi

VERSION_CHECK_BIN="$APP_DIR/Contents/Resources/collector"
HOST_ARCH="$(uname -m)"
if ! lipo -archs "$VERSION_CHECK_BIN" 2>/dev/null | grep -qw "$HOST_ARCH"; then
  echo "    ⚠️ collector 不含本机架构($HOST_ARCH),跳过版本一致性校验" >&2
elif ! BUNDLED_VER="$("$VERSION_CHECK_BIN" version 2>/dev/null)"; then
  echo "!! collector 跑不起来,无法校验版本(这本身就不正常)" >&2
  exit 1
elif [ "$BUNDLED_VER" != "$APP_VERSION" ]; then
  echo "!! App 与 collector 版本不一致:App=$APP_VERSION collector=$BUNDLED_VER" >&2
  echo "!! 版本号由 -ldflags 注入(见上面 go build collector 那段);若 collector 报 'dev'," >&2
  echo "!! 多半是 main.go 里 clientVersion 被改回 const 了——-X 对 const 静默失效。" >&2
  exit 1
else
  echo "    版本一致 App=$APP_VERSION collector=$BUNDLED_VER"
fi

if [ -n "$STAGE" ]; then
  if [ -e "$FINAL_APP_DIR" ]; then
    /usr/bin/python3 - "$STAGE" "$FINAL_APP_DIR" <<'SWAP'
import ctypes, sys
libc = ctypes.CDLL("/usr/lib/libSystem.dylib", use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
RENAME_SWAP = 0x00000002
if libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), RENAME_SWAP) != 0:
    import os
    sys.exit(f"renamex_np(RENAME_SWAP) failed: {os.strerror(ctypes.get_errno())}")
SWAP
  else
    mv "$STAGE" "$FINAL_APP_DIR"
  fi
  APP_DIR="$FINAL_APP_DIR"
  BIN="$APP_DIR/Contents/MacOS/lyrimuse"
  echo "==> installed → $FINAL_APP_DIR"
fi

if [ "$NO_RESTART" = 1 ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

if launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "==> legacy LaunchAgent job $LABEL is still loaded in this login session; booting it out"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  sleep 1
fi
OLD_PIDS="$(pgrep -f "$BIN" 2>/dev/null | tr '\n' ' ' || true)"
if [ -n "$OLD_PIDS" ]; then
  echo "==> stopping running instance (pid ${OLD_PIDS% })"
  kill $OLD_PIDS 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 1
  done
fi
echo "==> launching via LaunchServices (open -g)"
open -g "$APP_DIR"
pid=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pid="$(pgrep -f "$BIN" 2>/dev/null | tr '\n' ' ' || true)"
  [ -n "$pid" ] && break
  sleep 1
done
if [ -z "$pid" ]; then
  echo "!! $APP_NAME not running — check $LOG_FILE" >&2
  exit 1
fi
if [ -n "$OLD_PIDS" ] && [ "$pid" = "$OLD_PIDS" ]; then
  echo "!! $APP_NAME 旧实例没有退出(pid 仍是 ${pid% })。磁盘上已是新二进制,但内存里跑的还是旧的。" >&2
  echo "!! 最常见的原因:App 有 modal sheet 开着(设置 / 解析决策 / 搜索候选歌词 等弹窗)," >&2
  echo "!! AppKit 会把 terminate 整个取消掉,等多久都没用 —— 关掉那张面板再跑一次就行。" >&2
  echo "!! 想确认是不是这个原因:/usr/bin/log show --last 5m --predicate 'process == \"lyrimuse\"' | grep 'blocked by'" >&2
  exit 1
fi
echo "==> $APP_NAME running, pid ${pid% }"

COLLECTOR_PLIST="$HOME/Library/LaunchAgents/$COLLECTOR_LABEL.plist"
if [ -f "$COLLECTOR_PLIST" ]; then
  echo "==> reloading collector job (refreshing its launch constraint)"
  launchctl bootout "gui/$(id -u)/$COLLECTOR_LABEL" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$COLLECTOR_PLIST" 2>/dev/null || true
  sleep 1
  launchctl kickstart -k "gui/$(id -u)/$COLLECTOR_LABEL" 2>/dev/null || true
  sleep 2
  if cpid=$(pgrep -f "$APP_DIR/Contents/Resources/collector"); then
    echo "==> collector running, pid $cpid"
  else
    echo "!! collector not running — launchctl print gui/$(id -u)/$COLLECTOR_LABEL" >&2
  fi
fi
