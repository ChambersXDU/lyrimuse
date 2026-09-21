#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
UNINSTALL="$SCRIPT_DIR/uninstall.sh"
PROBE_B="me.yudaotor.lyrimuse.probe-uninstall-app"
FAKE_HOME="$(/usr/bin/mktemp -d /tmp/lyrimuse-uninstall-test.XXXXXX)"
FAILURES=0

cleanup() {
  /usr/bin/defaults delete "$PROBE_B" >/dev/null 2>&1
  /bin/rm -rf "$FAKE_HOME"
}
trap cleanup EXIT INT TERM

ok()   { echo "  ok   - $1" }
fail() { echo "  FAIL - $1"; FAILURES=$((FAILURES + 1)) }

REAL_CONFIG_BEFORE=$(/usr/bin/find "$HOME/.config/lyrimuse" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
real_defaults_count() {
  /usr/bin/defaults read me.yudaotor.lyrimuse 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '
}
REAL_DEFAULTS_BEFORE=$(real_defaults_count)

setup_fake_home() {
  /bin/rm -rf "$FAKE_HOME"
  /bin/mkdir -p "$FAKE_HOME/.config/lyrimuse/lyrics" "$FAKE_HOME/Library/Logs"
  echo '{}' > "$FAKE_HOME/.config/lyrimuse/config.json"
  echo '{}' > "$FAKE_HOME/.config/lyrimuse/lyrimuse-enrich-cache.json"
  echo '[00:01.00]假歌词' > "$FAKE_HOME/.config/lyrimuse/lyrics/测试 - 歌.lrc"
  echo 'log line' > "$FAKE_HOME/Library/Logs/lyrimuse-app.log"
  /usr/bin/defaults write "$PROBE_B" probeKey -string probeValue 2>/dev/null
}

run_uninstall() {
  LYRIMUSE_UNINSTALL_PREFIX="$FAKE_HOME" \
  LYRIMUSE_UNINSTALL_APP_LABEL="$PROBE_B" \
    "$UNINSTALL" "$@"
}

echo "=== 1. 只读模式什么都不该动 ==="
setup_fake_home
run_uninstall >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "配置还在" || fail "只读模式删了配置"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse-app.log" ]] && ok "日志还在" || fail "只读模式删了日志"

echo
echo "=== 2. --purge 输入 no 应当取消 ==="
echo "no" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "取消后配置还在" || fail "输入 no 却把数据删了"

echo
echo "=== 3. --purge 输入回车（空）应当取消 ==="
echo "" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "空输入按取消处理" || fail "空输入却把数据删了"

echo
echo "=== 4. --purge 输入 yes 才真的删 ==="
setup_fake_home
echo "yes" | run_uninstall --purge >/dev/null 2>&1
[[ -d "$FAKE_HOME/.config/lyrimuse" ]] && fail "配置目录没删" || ok "配置目录已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse-app.log" ]] && fail "日志没删" || ok "日志已删"
probe_defaults_left=$(/usr/bin/defaults read "$PROBE_B" 2>/dev/null | /usr/bin/tr -d '[:space:]')
[[ -z "$probe_defaults_left" || "$probe_defaults_left" == "{}" ]] \
  && ok "偏好设置项已删" || fail "偏好设置项没删（残留: $probe_defaults_left）"

echo
echo "=== 5. 全程没碰真实环境 ==="
REAL_CONFIG_AFTER=$(/usr/bin/find "$HOME/.config/lyrimuse" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[[ "$REAL_CONFIG_BEFORE" == "$REAL_CONFIG_AFTER" ]] \
  && ok "真实配置文件数不变（$REAL_CONFIG_BEFORE）" \
  || fail "真实配置被动了：$REAL_CONFIG_BEFORE -> $REAL_CONFIG_AFTER"
REAL_DEFAULTS_AFTER=$(real_defaults_count)
[[ "$REAL_DEFAULTS_BEFORE" == "$REAL_DEFAULTS_AFTER" ]] \
  && ok "真实偏好设置项不变（$REAL_DEFAULTS_BEFORE 行）" \
  || fail "真实偏好被动了：$REAL_DEFAULTS_BEFORE -> $REAL_DEFAULTS_AFTER 行"

echo
if (( FAILURES == 0 )); then
  echo "ALL PASS"
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
