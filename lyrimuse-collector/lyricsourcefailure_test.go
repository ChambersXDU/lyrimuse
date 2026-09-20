package main

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

const swiftFailureReasonPath = "../lyrimuse/Sources/lyrimuse/LyricSourceFailureReason.swift"

func TestLyricSourceFailureCodesMatchSwiftSide(t *testing.T) {
	goSrc, err := os.ReadFile("lyricsourcefailure.go")
	if err != nil {
		t.Fatal(err)
	}
	swiftSrc, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatalf("读不到 Swift 侧(%s): %v —— 文件挪了就把这里的路径一起改掉,别把守卫删掉", swiftFailureReasonPath, err)
	}

	goCodes := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\s*lyric(?:Failure|Test)Reason\w+\s*=\s*"([a-z0-9_]+)"`).
		FindAllStringSubmatch(string(goSrc), -1) {
		goCodes[m[1]] = true
	}

	swiftCodes := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\s*case "([a-z0-9_]+)":`).
		FindAllStringSubmatch(string(swiftSrc), -1) {
		swiftCodes[m[1]] = true
	}

	if len(goCodes) == 0 || len(swiftCodes) == 0 {
		t.Fatalf("正则一个都没抓到(go=%d swift=%d)—— 常量/switch 的写法变了,先修这个测试,别当没事", len(goCodes), len(swiftCodes))
	}
	if missing := diffCodes(goCodes, swiftCodes); len(missing) > 0 {
		t.Errorf("collector 有、Swift 侧 switch 没有:%v\n界面会原样显示这串代码本身。补 %s 的 case。",
			missing, swiftFailureReasonPath)
	}
	if extra := diffCodes(swiftCodes, goCodes); len(extra) > 0 {
		t.Errorf("Swift 侧有、collector 已经不再产出:%v\n要么是 collector 那边删漏了,要么是死代码。", extra)
	}
}

func TestMusixmatchDirectBlockedCodeIsWiredOnBothSides(t *testing.T) {
	if lyricFailureReasonMusixmatchDirectBlocked != "musixmatch_direct_blocked" {
		t.Fatalf("代码串变了:%q", lyricFailureReasonMusixmatchDirectBlocked)
	}
	swiftSrc, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(swiftSrc), `case "musixmatch_direct_blocked":`) {
		t.Error("Swift 侧没有 musixmatch_direct_blocked 的 case")
	}

	mm, err := os.ReadFile("musixmatch.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mm), "lyricFailureReasonMusixmatchDirectBlocked") {
		t.Error("musixmatch.go 没有把这个代码接到 dohHTTPClient 的 onBlocked 上")
	}
}

func TestTransportFailureCodesAreWired(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{lyricFailureReasonDNSFailed, "dns_failed"},
		{lyricFailureReasonConnectFailed, "connect_failed"},
		{lyricFailureReasonServerError, "server_error"},
		{lyricFailureReasonUpstreamUnreachable, "upstream_unreachable"},
	} {
		if c.got != c.want {
			t.Errorf("代码串变了:%q(应为 %q)", c.got, c.want)
		}
	}
	cli, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cli), "lyricSourceBreakerShared.transportFailureCodes()") {
		t.Error("searchcli.go 的 lyricSourceFailureReasons 没有消费 transportFailureCodes —— 三个代码永远报不出去")
	}

	br, err := os.ReadFile("sourcebreaker.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(br), "b.noteTransport(source, err, status, tr)") {
		t.Error("sourcebreaker.go 的 observeWith 没有调 noteTransport")
	}

	obs, err := os.ReadFile("networkobs.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, needle := range []string{"httptrace.WithClientTrace(", "DNSStart:", "DNSDone:", ".observeTraced("} {
		if !strings.Contains(string(obs), needle) {
			t.Errorf("networkobs.go 缺 %q —— DNS 轨迹没接上", needle)
		}
	}

	am, err := os.ReadFile("amllttml.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(am), "amllSkippedForMissingIDs.Store(true)") {
		t.Error("amllttml.go 没有在两个 ID 都为空时置位 amllSkippedForMissingIDs")
	}
}

func TestLyricSourceFailureReasonsWith(t *testing.T) {

	savedYT, savedMM, savedNE := ytmusicLastFailureReasonNow(), musixmatchLastFailureReasonNow(), neteaseLastFailureReasonNow()
	t.Cleanup(func() {
		ytmusicSetLastFailureReason(savedYT)
		musixmatchSetLastFailureReason(savedMM)
		neteaseSetLastFailureReason(savedNE)
	})
	musixmatchSetLastFailureReason("")
	neteaseSetLastFailureReason("")
	ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
	results := []scoredLyricCandidateResult{
		{Source: "musixmatch", Score: 300},
		{Source: "kuwo", Score: -1},
	}
	transport := map[string]string{
		"netease":   lyricFailureReasonDNSFailed,
		"qq":        lyricFailureReasonDNSFailed,
		"kugou":     lyricFailureReasonConnectFailed,
		"lrclib":    lyricFailureReasonServerError,
		"kuwo":      lyricFailureReasonDNSFailed,
		"migu":      lyricFailureReasonDNSFailed,
		"lyricfind": lyricFailureReasonConnectFailed,
	}
	enabled := func(s string) bool { return s != "migu" }
	got := lyricSourceFailureReasonsWith(results, transport, enabled, true)
	want := map[string]string{
		"netease":   lyricFailureReasonDNSFailed,
		"qq":        lyricFailureReasonDNSFailed,
		"kugou":     lyricFailureReasonConnectFailed,
		"lrclib":    lyricFailureReasonServerError,
		"lyricfind": lyricFailureReasonLyricFindRegionRestricted,
		"amll":      lyricFailureReasonUpstreamUnreachable,
	}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for s, code := range want {
		if got[s] != code {
			t.Errorf("%s: got %q want %q", s, got[s], code)
		}
	}

	oneSide := map[string]string{"netease": lyricFailureReasonDNSFailed}
	if r := lyricSourceFailureReasonsWith(nil, oneSide, enabled, true); r["amll"] != "" {
		t.Errorf("只有网易云死、QQ 正常:amll 缺 ID 是上游没这首,不该报 upstream_unreachable,得到 %q", r["amll"])
	}
	both := map[string]string{"netease": lyricFailureReasonDNSFailed, "qq": lyricFailureReasonConnectFailed}
	if r := lyricSourceFailureReasonsWith(nil, both, enabled, false); r["amll"] != "" {
		t.Errorf("amll 没有缺 ID 跳过(比如它自己发了请求)时不该派生,得到 %q", r["amll"])
	}
	amllAnswered := []scoredLyricCandidateResult{{Source: "amll", Score: 900}}
	if r := lyricSourceFailureReasonsWith(amllAnswered, both, enabled, true); r["amll"] != "" {
		t.Errorf("amll 给过候选就不该报任何代码,得到 %q", r["amll"])
	}

	amllOff := func(s string) bool { return s != "amll" }
	if r := lyricSourceFailureReasonsWith(nil, both, amllOff, true); r["amll"] != "" {
		t.Errorf("amll 关掉了不该报,得到 %q", r["amll"])
	}
	upstreamOff := func(s string) bool { return s != "netease" && s != "qq" }
	if r := lyricSourceFailureReasonsWith(nil, both, upstreamOff, true); r["amll"] != lyricFailureReasonUpstreamUnreachable {
		t.Errorf("网易云 / QQ 关掉但都连不上,amll 仍该报 upstream_unreachable,得到 %q", r["amll"])
	}
	if r := lyricSourceFailureReasonsWith(nil, both, upstreamOff, true); r["netease"] != "" || r["qq"] != "" {
		t.Errorf("关掉的源不该出现:%v", r)
	}
	ytmusicSetLastFailureReason("")
	if r := lyricSourceFailureReasonsWith(nil, nil, enabled, false); r != nil {
		t.Errorf("什么都没有时应返回 nil,得到 %v", r)
	}
}

const swiftSearchSheetPath = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchSheet.swift"

func TestSwiftSearchSheetTransportCodesMatchGo(t *testing.T) {
	src, err := os.ReadFile(swiftSearchSheetPath)
	if err != nil {
		t.Fatalf("读不到 %s: %v —— 文件挪了就改路径,别删守卫", swiftSearchSheetPath, err)
	}
	m := regexp.MustCompile(`transportFailureCodes\s*=\s*\[([^\]]*)\]`).FindStringSubmatch(string(src))
	if m == nil {
		t.Fatal("LyricsSearchSheet.swift 里没找到 `transportFailureCodes = [...]` 字面量 —— 写法变了先修这个测试")
	}
	swift := map[string]bool{}
	for _, q := range regexp.MustCompile(`"([a-z0-9_]+)"`).FindAllStringSubmatch(m[1], -1) {
		swift[q[1]] = true
	}
	goCodes := map[string]bool{}
	for _, c := range lyricSourceTransportFailureOrder {
		goCodes[c] = true
	}
	goCodes[lyricFailureReasonUpstreamUnreachable] = true
	if missing := diffCodes(goCodes, swift); len(missing) > 0 {
		t.Errorf("Go 有、Swift 空状态分组表没有:%v", missing)
	}
	if extra := diffCodes(swift, goCodes); len(extra) > 0 {
		t.Errorf("Swift 空状态分组表有、Go 不产出:%v", extra)
	}

	for code := range swift {
		if !strings.Contains(string(src), `case "`+code+`":`) {
			t.Errorf("transportFailureLine 没有 case %q", code)
		}
	}
}

func TestSwiftFailureReasonCasesActuallyTranslate(t *testing.T) {
	raw, err := os.ReadFile(swiftFailureReasonPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(raw), "\n")
	caseRe := regexp.MustCompile(`^\s*case "([a-z0-9_]+)":`)
	checked := 0
	for i, line := range lines {
		m := caseRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		checked++

		found := false
		for j := i + 1; j < len(lines) && j <= i+12; j++ {
			next := strings.TrimSpace(lines[j])
			if next == "" || strings.HasPrefix(next, "//") {
				continue
			}
			found = strings.HasPrefix(next, "return L10n.t(")
			break
		}
		if !found {
			t.Errorf("case %q 后面没有紧跟 return L10n.t(...) —— 要么忘了翻译,要么绕开了 L10n(英文界面会显示中文)", m[1])
		}
	}
	if checked == 0 {
		t.Fatal("一个 case 都没扫到 —— 正则失效,这个守卫已经形同虚设")
	}
}

func diffCodes(a, b map[string]bool) []string {
	var out []string
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
