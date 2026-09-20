#!/bin/zsh
set -u

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
UID_="$(id -u)"
PREFIX="me.yudaotor.lyrimuse.probe"
TMPDIR_="$(/usr/bin/mktemp -d /tmp/lyrimuse-launchd-probe.XXXXXX)"
PARSE=0
[[ "${1:-}" == "--parse" ]] && PARSE=1

cleanup() {
  for label in "$PREFIX.running" "$PREFIX.exited" "$PREFIX.quick"; do
    /bin/launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
  done
  /bin/rm -rf "$TMPDIR_"
}
trap cleanup EXIT INT TERM

assert_probe_label() {
  case "$1" in
    $PREFIX.*) ;;
    *) echo "!! 拒绝操作非 probe label: $1" >&2; exit 2 ;;
  esac
}

make_job() {
  local label="$1"; shift
  assert_probe_label "$label"
  local plist="$TMPDIR_/$label.plist"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>'
    echo "  <string>$*</string></array>"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><false/>'
    echo '</dict></plist>'
  } > "$plist"
  /bin/launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
  /bin/launchctl bootstrap "gui/$UID_" "$plist" 2>&1
}

show() {
  local label="$1" note="$2"
  /bin/launchctl print "gui/$UID_/$label" > "$TMPDIR_/$label.out" 2>&1
  local rc=$?
  echo "--- $note"
  echo "    print 退出码 = $rc"
  /usr/bin/grep -E "^	(state|pid|last exit code) = " "$TMPDIR_/$label.out" 2>/dev/null | /usr/bin/sed 's/^/    /'
  [[ $rc -ne 0 ]] && echo "    (无输出)"
  return 0
}

echo "=== 场景 1:注册 + 进程还活着 ==="
make_job "$PREFIX.running" "sleep 30" >/dev/null
/usr/bin/python3 -c 'import time; time.sleep(1.5)'
show "$PREFIX.running" "预期 state = running，带 pid"

echo
echo "=== 场景 2:注册 + 进程已退出（退出码 78）==="
make_job "$PREFIX.exited" "sleep 1; exit 78" >/dev/null
/usr/bin/python3 -c 'import time; time.sleep(4)'
show "$PREFIX.exited" "预期 state = not running，last exit code = 78: EX_CONFIG"

echo
echo "=== 场景 3:未注册 ==="
show "$PREFIX.never-created" "预期退出码 113"

if [[ $PARSE -eq 1 ]]; then
  echo
  echo "=== 用 LaunchdPrintParser 解析上面的真实输出 ==="
  CORE="$REPO_ROOT/lyrimuse/Sources/LyrimuseCore/Local/LaunchdJobState.swift"
  if [[ ! -f "$CORE" ]]; then
    echo "找不到 $CORE"; exit 1
  fi
  DRIVER="$TMPDIR_/parse.swift"
  /bin/cat "$CORE" > "$DRIVER"
  /bin/cat >> "$DRIVER" <<'SWIFT'
let args = Array(CommandLine.arguments.dropFirst())
for spec in args {
    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
    let (label, path) = (parts[0], parts[1])
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let exitCode: Int32 = text.contains(" = {") ? 0 : 113
    print("  \(label) -> \(LaunchdPrintParser.parse(printExitCode: exitCode, printOutput: text))")
}
SWIFT
  swift "$DRIVER" \
    "场景1(在跑)|$TMPDIR_/$PREFIX.running.out" \
    "场景2(已退出)|$TMPDIR_/$PREFIX.exited.out" \
    "场景3(未注册)|$TMPDIR_/$PREFIX.never-created.out"
fi

echo
echo "=== 清理 ==="
cleanup
trap - EXIT INT TERM
for label in "$PREFIX.running" "$PREFIX.exited"; do
  if /bin/launchctl print "gui/$UID_/$label" >/dev/null 2>&1; then
    echo "❌ 仍然注册着: $label"; exit 1
  fi
done
echo "✅ 所有 probe job 已注销"
echo
echo "真实服务未被触碰:"
for label in com.lyrimuse.collector me.yudaotor.lyrimuse; do
  printf "   %-26s " "$label"
  /bin/launchctl print "gui/$UID_/$label" 2>/dev/null | /usr/bin/grep -E "^	state = " || echo "(未注册)"
done
