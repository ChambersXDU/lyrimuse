#!/bin/zsh
set -u

PREFIX="${LYRIMUSE_UNINSTALL_PREFIX:-$HOME}"
APP_LABEL="${LYRIMUSE_UNINSTALL_APP_LABEL:-me.yudaotor.lyrimuse}"
CONFIG_DIR="$PREFIX/.config/lyrimuse"
APP_LOG_FILE="$PREFIX/Library/Logs/lyrimuse-app.log"

MODE="report"
case "${1:-}" in
  "")         MODE="report" ;;
  --purge)    MODE="purge" ;;
  -h|--help)
    cat <<'EOF'
卸载 Lyrimuse 留在系统里的东西。

  ./uninstall.sh
  ./uninstall.sh --purge
EOF
    exit 0 ;;
  *) echo "不认识的参数: $1（试试 --help）" >&2; exit 2 ;;
esac

human_size() {
  [[ -e "$1" ]] || { echo "-"; return }
  /usr/bin/du -sh "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
}

has_defaults() {
  local out
  out=$(/usr/bin/defaults read "$1" 2>/dev/null) || return 1
  local squeezed="${out//[[:space:]]/}"
  [[ -n "$squeezed" && "$squeezed" != "{}" ]]
}

echo "=== 当前状态 ==="
for p in "$CONFIG_DIR" "$APP_LOG_FILE"; do
  if [[ -e "$p" ]]; then
    echo "  存在  $p  ($(human_size "$p"))"
  else
    echo "  没有  $p"
  fi
done
if has_defaults "$APP_LABEL"; then
  echo "  存在  偏好设置项 $APP_LABEL"
else
  echo "  没有  偏好设置项 $APP_LABEL"
fi

if [[ "$MODE" == "report" ]]; then
  echo
  echo "只是看看，什么都没动。"
  echo "  连同配置/缓存/日志和偏好一起删除:  $0 --purge"
  echo "  App 本体请手动拖进废纸篓。"
  exit 0
fi

unregister_login_item() {
  local app_bin="/Applications/Lyrimuse.app/Contents/MacOS/lyrimuse"
  [[ "$PREFIX" == "$HOME" && -x "$app_bin" ]] || return 0
  if "$app_bin" --unregister-login-item >/dev/null 2>&1; then
    echo "  ✅ 已注销系统登录项(开机启动)"
  else
    echo "  ⚠️ 注销登录项失败,请到「系统设置 → 通用 → 登录项」手动移除 Lyrimuse"
  fi
}

echo
echo "=== 将要删除的数据（不可恢复）==="
TO_DELETE=()
HAS_DEFAULTS=no
has_defaults "$APP_LABEL" && HAS_DEFAULTS=yes
[[ -e "$CONFIG_DIR" ]] && TO_DELETE+=("$CONFIG_DIR")
[[ -e "$APP_LOG_FILE" ]] && TO_DELETE+=("$APP_LOG_FILE")
if (( ${#TO_DELETE[@]} == 0 )); then
  echo "  （没有数据文件）"
else
  for p in "${TO_DELETE[@]}"; do
    echo "  $p  ($(human_size "$p"))"
  done
  LYRICS_DIR="$CONFIG_DIR/lyrics"
  if [[ -d "$LYRICS_DIR" ]]; then
    n=$(/usr/bin/find "$LYRICS_DIR" -type f \( -name '*.lrc' -o -name '*.yrc' \) 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo
    echo "  ⚠️ 其中包含 $n 个已导出的歌词文件(.lrc/.tr.lrc/.roma.lrc/.yrc)。里面可能有你"
    echo "     手工修正过的内容，删掉之后没有任何办法找回。想留着的话现在先把整个"
    echo "     lyrics/ 目录拷走。"
  fi
fi
if [[ "$HAS_DEFAULTS" == "yes" ]]; then
  echo
  echo "  偏好设置项(UserDefaults 域 $APP_LABEL)：外观/快捷键/歌词时间轴校正值等全部设置"
  echo "  ⚠️ 其中包含你为单曲手调出来的歌词时间轴校正值 —— 那是一句句听出来的，删掉不可恢复。"
fi

echo
printf "确认删除？输入 yes 继续（其它任何输入都会取消）: "
read -r answer
if [[ "$answer" != "yes" ]]; then
  echo "已取消，什么都没动。"
  exit 0
fi

unregister_login_item
echo
echo "=== 删除数据 ==="
for p in "${TO_DELETE[@]}"; do
  /bin/rm -rf "$p" && echo "  ✅ 已删除 $p"
done

echo
echo "=== 删除偏好设置项 ==="
if [[ "$HAS_DEFAULTS" == "yes" ]]; then
  /usr/bin/defaults delete "$APP_LABEL" >/dev/null 2>&1
  if has_defaults "$APP_LABEL"; then
    echo "  ❌ $APP_LABEL 仍然存在，手动执行: defaults delete $APP_LABEL"
  else
    echo "  ✅ 已删除偏好设置项 $APP_LABEL"
  fi
else
  echo "  —  本来就没有 $APP_LABEL"
fi
echo
echo "App 本体请自行拖进废纸篓: /Applications/Lyrimuse.app"
