#!/usr/bin/env bash
# Lyrimuse Application Build & Packaging Script
#
# Builds the Lyrimuse .app bundle and installs it into /Applications (or custom destination).
# Operates as an accessory UI application (LSUIElement = true) that runs in the menu bar/notch.
#
# Usage:
#   ./build.sh                Build host architecture, install to /Applications, restart running instance
#   ./build.sh --universal    Build universal binary (arm64 + x86_64) for Intel Mac compatibility
#   ./build.sh --no-restart   Build without restarting running application
#   ./build.sh --dest <path>  Assemble bundle into specified path instead of /Applications
#
# Packaging Architecture:
# - Default builds target the host architecture (arm64 on Apple Silicon) to avoid Rosetta deprecation warnings.
# - Universal bundles (--universal) provide both arm64 and x86_64 slices for Intel Mac compatibility.
# - Package distribution uses separate assets for native arm64 and universal builds.
# - Sparkle appcast gates arm64-only builds via <sparkle:hardwareRequirements>arm64</...>.
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/

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

# Code signing identity resolution. Defaults to ad-hoc ("-") when no signing identity is available.
# When a local self-signed certificate ("Lyrimuse Dev Signing") is present in login keychain,
# signing with it preserves TCC accessibility and automation permissions across rebuilds
# (avoiding cdhash invalidation from ad-hoc signatures).
# Set LYRIMUSE_SIGN_ID to explicitly override this identity (e.g. LYRIMUSE_SIGN_ID="-").
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
# When --dest is provided, avoid touching running instances.
[ -n "$DEST" ] && NO_RESTART=1
# Single slice binaries are copied directly without single-arch fat headers.
merge_slices() {
  local out="$1"; shift
  if [ "$#" -eq 1 ]; then cp "$1" "$out"; else lipo -create "$@" -output "$out"; fi
}

APP_NAME="Lyrimuse"
# Bundle ID (matching LaunchAgent label) and collector job label match LyrimuseIdentity definitions.
LABEL="me.yudaotor.lyrimuse"
COLLECTOR_LABEL="com.lyrimuse.collector"
LOG_FILE="$HOME/Library/Logs/lyrimuse.log"
# Display version (CFBundleShortVersionString) derived from git tag (stripping leading 'v').
# Sparkle compares versions via CFBundleVersion computed by scripts/build-version.sh.
# Release workflows (release.yml) supply LYRIMUSE_VERSION from tag; local runs default to latest tag or 0.0.0.
APP_VERSION="${LYRIMUSE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
[ -z "$APP_VERSION" ] && APP_VERSION="0.0.0"
# CFBundleVersion computed from display version via scripts/build-version.sh.
BUILD_VERSION="$(./scripts/build-version.sh "$APP_VERSION")" || {
  echo "!! 版本号形态不合法: $APP_VERSION(要 X.Y.Z 或 X.Y.Z-alpha|beta|rc.N,见 scripts/build-version.sh)" >&2
  exit 1
}
# Destination bundle layout:
# Default installs directly to /Applications/${APP_NAME}.app.
# Staging occurs in a temporary sibling directory (.${APP_NAME}.app.stage.$$) on the same APFS volume,
# followed by an atomic renamex_np swap to ensure concurrent processes or launchd read intact bundles.
# When --dest is specified (e.g. package.sh), staging is skipped and destination is used directly.
FINAL_APP_DIR="${DEST:-/Applications/${APP_NAME}.app}"
if [ -n "$DEST" ]; then
  APP_DIR="$FINAL_APP_DIR"
  STAGE=""
else
  # Clear stale staging directories from previous runs.
  for stale in "$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage."*; do
    [ -e "$stale" ] && rm -rf "$stale"
  done
  STAGE="$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage.$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  # Trap cleans up staging directory on exit. Following atomic swap, $STAGE holds previous bundle.
  trap 'rm -rf "$STAGE"' EXIT
  APP_DIR="$STAGE"
fi
BIN="$APP_DIR/Contents/MacOS/lyrimuse"
# Bundle identifier and launchd label share the same reverse-domain identifier ($LABEL).
# Temporary directory for merged multi-architecture fat slices (per-run mktemp -d prevents concurrent build collisions).
FAT_DIR="$(mktemp -d)"

echo "==> building (release) [$ARCHES]"
# Compile each architecture slice separately and combine via lipo, avoiding Xcode xcbuild dependency.
SWIFT_SLICES=()
TRANSLATE_SLICES=()
ROMANIZE_SLICES=()
# LYRIMUSE_SPM_CACHE_PATH / LYRIMUSE_SPM_SCRATCH_PATH:
# Redirect SwiftPM cache and scratch paths for sandboxed package manager builds (e.g. MacPorts).
SPM_PATH_ARGS=()
[ -n "${LYRIMUSE_SPM_CACHE_PATH:-}" ] && SPM_PATH_ARGS+=(--cache-path "$LYRIMUSE_SPM_CACHE_PATH")
[ -n "${LYRIMUSE_SPM_SCRATCH_PATH:-}" ] && SPM_PATH_ARGS+=(--scratch-path "$LYRIMUSE_SPM_SCRATCH_PATH")
for arch in $ARCHES; do
  swift build -c release --arch "$arch" ${SPM_PATH_ARGS[@]+"${SPM_PATH_ARGS[@]}"}
  # Query binary output directory via --show-bin-path.
  BIN_PATH="$(swift build -c release --arch "$arch" ${SPM_PATH_ARGS[@]+"${SPM_PATH_ARGS[@]}"} --show-bin-path)"
  SWIFT_SLICES+=("$BIN_PATH/lyrimuse")
  TRANSLATE_SLICES+=("$BIN_PATH/lyrics-translate")
  ROMANIZE_SLICES+=("$BIN_PATH/lyrics-romanize")
done
merge_slices "$FAT_DIR/lyrimuse" "${SWIFT_SLICES[@]}"
merge_slices "$FAT_DIR/lyrics-translate" "${TRANSLATE_SLICES[@]}"
merge_slices "$FAT_DIR/lyrics-romanize" "${ROMANIZE_SLICES[@]}"

# Build collector background service bundled into Contents/Resources/collector.
echo "==> building collector [$ARCHES]"
# Collector is pure Go (no cgo); cross-compiles across GOARCH targets and merges via lipo.
COLLECTOR_SLICES=()
for arch in $ARCHES; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "!! 不认识的架构:$arch" >&2; exit 2 ;;
  esac
  out="$FAT_DIR/collector-$arch"
  # -ldflags -X: Injects version into collector binary to ensure version parity with App.
  # Note: Target variable clientVersion must be a 'var' in Go; -X silently fails on 'const'.
  # LYRIMUSE_GOTOOLCHAIN allows overriding the default toolchain (e.g. offline package manager sandboxes).
  (cd ../lyrimuse-collector && GOTOOLCHAIN="${LYRIMUSE_GOTOOLCHAIN:-go1.24.4}" GOOS=darwin GOARCH="$goarch" \
    go build -ldflags "-X main.clientVersion=$APP_VERSION" -o "$out" .)
  COLLECTOR_SLICES+=("$out")
done
merge_slices "$FAT_DIR/collector" "${COLLECTOR_SLICES[@]}"

echo "==> assembling .app bundle"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$FAT_DIR/lyrimuse" "$BIN"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# Collector binary is placed in Contents/Resources/ as a background helper service managed by launchd.
# Remove destination before copying to allocate a new inode, preventing kernel codesigning cache staleness.
rm -f "$APP_DIR/Contents/Resources/collector"
cp "$FAT_DIR/collector" "$APP_DIR/Contents/Resources/collector"
# Re-sign collector after lipo, as lipo invalidates previous toolchain signatures.
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/collector"

# Standalone helper for translation requests via Apple Translation framework.
rm -f "$APP_DIR/Contents/Resources/lyrics-translate"
cp "$FAT_DIR/lyrics-translate" "$APP_DIR/Contents/Resources/lyrics-translate"
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/lyrics-translate"

# Standalone helper for Japanese romanization via CFStringTokenizer/ICU.
rm -f "$APP_DIR/Contents/Resources/lyrics-romanize"
cp "$FAT_DIR/lyrics-romanize" "$APP_DIR/Contents/Resources/lyrics-romanize"
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/lyrics-romanize"

# Bundles ungive/media-control for system-level MediaRemote tracking (for media players lacking AppleScript support).
# Preserves the relative directory structure (bin/, lib/, Frameworks/) inside Contents/Resources/media-control.
# LYRIMUSE_MEDIA_CONTROL_PREFIX allows specifying custom installation path in offline sandboxes (e.g. MacPorts).
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
  # Clean destination before copying to remove read-only file permissions and stale inodes.
  # Selectively bundle required components rather than entire prefix to support shared prefix package managers.
  rm -rf "$APP_DIR/Contents/Resources/media-control"
  mkdir -p "$APP_DIR/Contents/Resources/media-control/bin" \
           "$APP_DIR/Contents/Resources/media-control/lib" \
           "$APP_DIR/Contents/Resources/media-control/Frameworks"
  cp "$MEDIA_CONTROL_PREFIX/bin/media-control" "$APP_DIR/Contents/Resources/media-control/bin/"
  cp -R "$MEDIA_CONTROL_PREFIX/lib/media-control" "$APP_DIR/Contents/Resources/media-control/lib/media-control"
  MC_FW_SRC="$MEDIA_CONTROL_PREFIX/Frameworks/MediaRemoteAdapter.framework"
  [ -d "$MC_FW_SRC" ] || MC_FW_SRC="$MEDIA_CONTROL_PREFIX/Library/Frameworks/MediaRemoteAdapter.framework"
  # Use ditto to preserve symlinks inside framework (Versions/Current).
  ditto "$MC_FW_SRC" "$APP_DIR/Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework"
  chmod -R u+w "$APP_DIR/Contents/Resources/media-control"
  # Adjust framework search path inside script to match bundle structure.
  /usr/bin/sed -i '' "s|'\.\.', 'Library', 'Frameworks', 'MediaRemoteAdapter.framework'|'..', 'Frameworks', 'MediaRemoteAdapter.framework'|" \
    "$APP_DIR/Contents/Resources/media-control/bin/media-control"
  # Sign media-control executable with designated identity.
  codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Resources/media-control/bin/media-control"
  # In universal builds, merge x86_64 slice for media-control from Homebrew bottle blob.
  # Verifies SHA256 checksum against pinned formula before extracting and lipo-merging.
  if [ "$UNIVERSAL" = 1 ]; then
    MC_FW="$APP_DIR/Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework"
    if [ -n "${LYRIMUSE_MEDIA_CONTROL_PREFIX:-}" ]; then
      MC_VER="$(basename "$MEDIA_CONTROL_PREFIX")"
    else
      MC_VER="$(brew list --versions media-control | awk '{print $2}')"
    fi
    # Pinned to media-control 0.7.6 x86_64 bottle (sonoma) on ghcr.io with SHA256 verification.
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
  # Inherit existing media-control bundle from final destination if available,
  # preventing regression when Homebrew is absent during rebuilds.
  if [ -n "$STAGE" ] && [ -d "$FINAL_APP_DIR/Contents/Resources/media-control" ]; then
    ditto "$FINAL_APP_DIR/Contents/Resources/media-control" "$APP_DIR/Contents/Resources/media-control"
    echo "    media-control 从现装包继承(brew 里没找到,保持已装版本不被降级)"
  fi
  echo "!! media-control not found (brew install media-control) — QQ 音乐支持这次构建不可用,Apple Music 不受影响" >&2
fi

# Embed Sparkle.framework for automatic software updates:
# 1) Use ditto to preserve symlinks (Versions/Current).
# 2) Add @executable_path/../Frameworks rpath to main binary.
# 3) Inside-out code signing for embedded XPC services and framework.
SPM_SCRATCH="${LYRIMUSE_SPM_SCRATCH_PATH:-.build}"
SPARKLE_FW_SRC="$(find "$SPM_SCRATCH/artifacts" -type d -name "Sparkle.framework" -path "*/Sparkle.xcframework/*" 2>/dev/null | head -1)"
# Skip framework embed when Sparkle is not configured as a dependency (e.g. package managers like MacPorts).
if [ -z "$SPARKLE_FW_SRC" ] && ! grep -q 'sparkle-project/Sparkle' Package.swift; then
  echo "    Sparkle not a dependency — skipping framework embed (no in-app updater)"
  SPARKLE_SKIPPED=1
fi
if [ "${SPARKLE_SKIPPED:-0}" = 0 ] && [ ! -d "$SPARKLE_FW_SRC" ]; then
  echo "!! Sparkle.framework not found under $SPM_SCRATCH/artifacts — did 'swift package resolve' run?" >&2
  exit 1
fi
if [ "${SPARKLE_SKIPPED:-0}" = 0 ]; then
mkdir -p "$APP_DIR/Contents/Frameworks"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FW_SRC" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# Thin Sparkle framework to host architecture when not building universal bundle.
if [ "$UNIVERSAL" = 0 ]; then
  while IFS= read -r f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    case "$archs" in
      *" "*) lipo -thin "$ARCHES" "$f" -output "$f.thin" && mv "$f.thin" "$f" ;;
    esac
  done < <(find "$APP_DIR/Contents/Frameworks/Sparkle.framework" -type f)
  echo "    Sparkle.framework thinned to $ARCHES"
fi
# Verify existing rpaths via otool to ensure idempotent install_name_tool invocations.
if ! otool -l "$BIN" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
fi
find "$APP_DIR/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign "$SIGN_ID" {} \;
codesign --force --sign "$SIGN_ID" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
echo "    Sparkle.framework embedded + signed"
fi  # SPARKLE_SKIPPED
# Copy localization strings (.lproj) directly into Contents/Resources/.
# Remove existing destination directories first to avoid nested directory creation on rebuild.
rm -rf "$APP_DIR/Contents/Resources/zh-hans.lproj" "$APP_DIR/Contents/Resources/zh-hant.lproj" "$APP_DIR/Contents/Resources/en.lproj"
cp -R Sources/lyrimuse/Resources/zh-hans.lproj "$APP_DIR/Contents/Resources/zh-hans.lproj"
cp -R Sources/lyrimuse/Resources/zh-hant.lproj "$APP_DIR/Contents/Resources/zh-hant.lproj"
cp -R Sources/lyrimuse/Resources/en.lproj "$APP_DIR/Contents/Resources/en.lproj"
# Copy all bundled icon and image assets.
for png in Sources/lyrimuse/Resources/*.png; do
  cp "$png" "$APP_DIR/Contents/Resources/$(basename "$png")"
done
# Distribute third-party license text alongside .app bundle per licensing terms (media-control, Sparkle, KeyboardShortcuts).
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
    <!-- URL scheme for Last.fm OAuth callback (lyrimuse://lastfm-auth-callback). -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${LABEL}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>lyrimuse</string>
            </array>
        </dict>
    </array>
    <key>SUFeedURL</key>
    <string>https://github.com/Yudaotor/lyrimuse/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>xTGKkA2z7gn42F0oyb6Qe4YyL+G/RTsKu5jvvsfytTE=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <!-- Default preferences for Sparkle automatic update checking and installation. -->
    <key>SUAutomaticallyUpdate</key>
    <true/>
</dict>
</plist>
PLIST

# Resources are placed in Contents/Resources/ conforming to Apple bundle layout guidelines.
# Code signing verifies resource integrity within Contents/Resources/.

# Sign the entire .app bundle using the resolved $SIGN_ID and fixed bundle identifier ($LABEL).
# Passing a fixed identifier ensures TCC permission grants remain valid across rebuilds.
codesign -s "$SIGN_ID" --force --identifier "$LABEL" "$APP_DIR"
codesign -v "$APP_DIR" && echo "    signature valid"
# Verify embedded collector signature.
codesign -v "$APP_DIR/Contents/Resources/collector" && echo "    collector signature valid"

# Architecture verification: ensure all Mach-O binaries match requested target architectures ($ARCHES).
echo "==> architecture check [$ARCHES]"
ARCH_BAD=""
while IFS= read -r f; do
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [ -z "$archs" ] && continue # 脚本/资源文件,没有架构这回事
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

# Verify version parity between App and bundled collector binary before installation.
VERSION_CHECK_BIN="$APP_DIR/Contents/Resources/collector"
# Cross-compiled binaries may not include host architecture; skip version verification if non-executable on host.
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

# Atomically replace installed bundle in /Applications via APFS renamex_np(RENAME_SWAP).
# Ensures uninterrupted availability for concurrent launchd tasks and running processes.
# Falls back to standard mv on first installation.
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

# Restart application via LaunchServices (open -g) to inherit proper scheduling priority and app lifecycle.
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
# Wait up to 10 seconds for LaunchServices registration to complete.
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
# Verify that the running process PID has changed. If the PID matches the previous instance,
# termination was prevented (e.g. AppKit blocks application termination when a modal sheet is open).
if [ -n "$OLD_PIDS" ] && [ "$pid" = "$OLD_PIDS" ]; then
  echo "!! $APP_NAME 旧实例没有退出(pid 仍是 ${pid% })。磁盘上已是新二进制,但内存里跑的还是旧的。" >&2
  echo "!! 最常见的原因:App 有 modal sheet 开着(设置 / 解析决策 / 搜索候选歌词 等弹窗)," >&2
  echo "!! AppKit 会把 terminate 整个取消掉,等多久都没用 —— 关掉那张面板再跑一次就行。" >&2
  echo "!! 想确认是不是这个原因:/usr/bin/log show --last 5m --predicate 'process == \"lyrimuse\"' | grep 'blocked by'" >&2
  exit 1
fi
echo "==> $APP_NAME running, pid ${pid% }"

# Reload collector LaunchAgent job to refresh kernel code requirements (LWCR) after binary update.
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
    # 不 exit 1:App 本身已经起来了，collector 没起来是个独立故障，值得刺眼但不该让
    # 整个构建被判失败(而且这条分支真出现时，多半要人去看崩溃报告)。
    echo "!! collector not running — launchctl print gui/$(id -u)/$COLLECTOR_LABEL" >&2
  fi
fi
