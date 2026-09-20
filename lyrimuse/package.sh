#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
DIST="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"
DMG_BACKGROUND="$STAGE/dmg-background.tiff"

VARIANTS=(
  "|--dest|arm64"
  "-intel|--universal --dest|arm64 x86_64"
)

echo "==> building variants"
VERSION=""
for v in "${VARIANTS[@]}"; do
  suffix="${v%%|*}"; rest="${v#*|}"; flags="${rest%%|*}"; want="${rest##*|}"
  label="${suffix:-(主包)}"
  echo "--> $label [$want]"
  app="$STAGE/${suffix:-primary}/Lyrimuse.app"
  ./build.sh $flags "$app" > "$STAGE/build${suffix}.log" 2>&1 || {
    echo "!! build.sh 失败,日志尾部:" >&2; tail -20 "$STAGE/build${suffix}.log" >&2; exit 1
  }
  ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
  [ -n "$ver" ] || { echo "!! 读不出 CFBundleShortVersionString" >&2; exit 1; }
  if [ -z "$VERSION" ]; then VERSION="$ver"; elif [ "$VERSION" != "$ver" ]; then
    echo "!! 两个变体版本号不一致($VERSION vs $ver)" >&2; exit 1
  fi

  bad=""
  while IFS= read -r f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    [ -z "$archs" ] && continue
    for a in $want; do
      case " $archs " in *" $a "*) ;; *) bad="$bad ${f#$app/}(缺$a)" ;; esac
    done
    for a in $archs; do
      case " $want " in *" $a "*) ;; *) bad="$bad ${f#$app/}(多余$a)" ;; esac
    done
  done < <(find "$app" -type f)
  if [ -n "$bad" ]; then
    echo "!! $label 架构与期望[$want]不符,拒绝打包:" >&2
    for f in $bad; do echo "     $f" >&2; done
    exit 1
  fi
  codesign -v --deep --strict "$app"
  echo "    架构与签名校验通过"
done

rm -rf "$DIST"
mkdir -p "$DIST"

human_size() {
  /usr/bin/python3 -c "import sys;n=int(sys.argv[1]);print(f'{n/1048576:.2f} MB' if n>=1048576 else (f'{n/1024:.1f} KB' if n>=1024 else f'{n} B'))" "$(stat -f %z "$1")"
}

echo "==> packaging"
for v in "${VARIANTS[@]}"; do
  suffix="${v%%|*}"
  app="$STAGE/${suffix:-primary}/Lyrimuse.app"
  base="Lyrimuse-v$VERSION-macos$suffix"

  ditto -c -k --sequesterRsrc --keepParent "$app" "$DIST/$base.zip"
  (cd "$DIST" && shasum -a 256 "$base.zip" > "$base.zip.sha256")

  volname="Lyrimuse${suffix:+ (Intel)}"
  dmgstage="$STAGE/dmg$suffix"
  rm -rf "$dmgstage"; mkdir -p "$dmgstage"
  ditto "$app" "$dmgstage/Lyrimuse.app"

  if "$PYTHON_BIN" -c "import dmgbuild" >/dev/null 2>&1; then
    if [ ! -f "$DMG_BACKGROUND" ]; then
      swift "$ROOT/scripts/make_dmg_background.swift" "$DMG_BACKGROUND"
    fi
    LYRIMUSE_DMG_APP="$dmgstage/Lyrimuse.app" \
    LYRIMUSE_DMG_VOLNAME="$volname" \
    LYRIMUSE_DMG_BACKGROUND="$DMG_BACKGROUND" \
      "$PYTHON_BIN" -m dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
        "$volname" "$DIST/$base.dmg" >/dev/null
  else
    echo "    (没装 dmgbuild,退回纯 hdiutil:产物功能一样,只是没有背景图和图标摆位)"
    ln -s /Applications "$dmgstage/Applications"
    hdiutil create -volname "$volname" -srcfolder "$dmgstage" \
      -fs HFS+ -format UDZO -ov -quiet "$DIST/$base.dmg"
  fi

  printf "    %-40s %s\n" "$base.zip" "$(human_size "$DIST/$base.zip")"
  printf "    %-40s %s\n" "$base.zip.sha256" "$(human_size "$DIST/$base.zip.sha256")"
  printf "    %-40s %s\n" "$base.dmg" "$(human_size "$DIST/$base.dmg")"
done

PRIMARY="Lyrimuse-v$VERSION-macos"
INTEL="Lyrimuse-v$VERSION-macos-intel"
echo
echo "==> 剩下的手工步骤(这个脚本故意不做):"
echo "    1) gh release create v$VERSION --title \"Lyrimuse v$VERSION\" \\"
echo "         dist/$PRIMARY.zip dist/$PRIMARY.zip.sha256 dist/$PRIMARY.dmg \\"
echo "         dist/$INTEL.zip dist/$INTEL.zip.sha256 dist/$INTEL.dmg"
echo "       release notes 里写清楚:普通用户下不带后缀那份,Intel Mac 下 -intel 那份"
echo "    2) 更新 Homebrew cask(Yudaotor/homebrew-lyrimuse):version + sha256,"
echo "       并加 depends_on arch: :arm64(cask 装的是主包,Intel 机器该被拒绝而不是装个跑不了的)"
echo "       主包 sha256 = $(awk '{print $1}' "$DIST/$PRIMARY.zip.sha256")"
