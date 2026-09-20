package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseLRCLines(t *testing.T) {
	in := strings.Join([]string{
		"[by:someone]",
		"[00:00.00] 作词 : Lenny Kravitz",
		"[00:20.94]我的生命",
		"[01:02]无小数的时间戳也要认",
		"[01:05:30]冒号做小数分隔符的变体",
		"[00:30.00]   ",
		"没有时间戳的一行",
	}, "\n")
	got := parseLRCLines(in)
	want := []lrcLine{
		{"[00:00.00]", "作词 : Lenny Kravitz"},
		{"[00:20.94]", "我的生命"},
		{"[01:02]", "无小数的时间戳也要认"},
		{"[01:05:30]", "冒号做小数分隔符的变体"},
	}
	if len(got) != len(want) {
		t.Fatalf("解析出 %d 行,期望 %d 行: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 行 = %+v, 期望 %+v", i, got[i], want[i])
		}
	}
}

func TestChunkForTranslationNeverSplitsALine(t *testing.T) {
	var texts []string
	for i := 0; i < 40; i++ {
		texts = append(texts, strings.Repeat("x", 30))
	}
	chunks := chunkForTranslation(texts)
	var flat []string
	for _, c := range chunks {
		joined := strings.Join(c, "\n")
		if len(joined) > translateMaxChunkChars {
			t.Errorf("有块超过上限: %d > %d", len(joined), translateMaxChunkChars)
		}
		flat = append(flat, c...)
	}
	if len(flat) != len(texts) {
		t.Fatalf("分块前后行数变了: %d → %d", len(texts), len(flat))
	}
	for i := range texts {
		if flat[i] != texts[i] {
			t.Fatalf("第 %d 行内容变了", i)
		}
	}
}

func TestChunkForTranslationOversizedSingleLine(t *testing.T) {
	long := strings.Repeat("y", translateMaxChunkChars+50)
	chunks := chunkForTranslation([]string{"短行", long, "另一短行"})

	for _, c := range chunks {
		if len(c) > 1 && len(strings.Join(c, "\n")) > translateMaxChunkChars {
			t.Errorf("超长行没有单独成块: %v", c)
		}
	}
}

func TestLineNeedsTranslation(t *testing.T) {
	cases := []struct {
		name, text, target string
		want               bool
	}{
		{"中文行 + 目标中文:不用翻", "我们的时光 一起走过的日子", "zh-CN", false},

		{"行内混排、主体中文:不用翻", "我们的时光 baby 一起走过", "zh-CN", false},

		{"整行英文:要翻", "It represent my heart!", "zh-CN", true},
		{"纯英文行:要翻", "The painful youth I've had", "zh-CN", true},
		{"日文行:要翻(假名不是汉字)", "君のことが好きだから", "zh-CN", true},
		{"纯符号/数字:没什么可翻", "♪ 1 2 3 —— ", "zh-CN", false},
		{"目标是英文时,英文行不用翻", "It represent my heart!", "en", false},
		{"目标是英文时,中文行要翻", "我们的时光", "en", true},
	}
	for _, c := range cases {
		if got := lineNeedsTranslation(c.text, c.target); got != c.want {
			t.Errorf("%s: lineNeedsTranslation(%q, %q) = %v, want %v",
				c.name, c.text, c.target, got, c.want)
		}
	}
}

func TestAnyLineNeedsTranslationMixedSong(t *testing.T) {

	mixed := "[00:16.73]你问我爱你有多深\n" +
		"[00:21.30]我爱你有几分\n" +
		"[00:24.71]我的情也真我的爱也真\n" +
		"[00:29.31]月亮代表我的心\n" +
		"[01:02.00]It represent my heart!\n" +
		"[01:06.00]It represent my heart!\n"
	if !anyLineNeedsTranslation(mixed, "zh-CN") {
		t.Error("华语歌夹整行英文副歌:应当放行去翻那几行英文" +
			"(2026-08-23 之前被 looksLikeTargetLanguage 整首跳过)")
	}

	allZh := "[00:01.00]你问我爱你有多深\n[00:05.00]月亮代表我的心\n"
	if anyLineNeedsTranslation(allZh, "zh-CN") {
		t.Error("整首中文不该触发翻译")
	}

	inline := "[00:01.00]我们的时光 baby 一起走过\n[00:05.00]我的情也真 oh 我的爱也真\n"
	if anyLineNeedsTranslation(inline, "zh-CN") {
		t.Error("行内混排(每行汉字仍占多数)不该触发翻译")
	}

	latinHeavy := "[00:01.00]说好不哭 oh yeah\n"
	if !anyLineNeedsTranslation(latinHeavy, "zh-CN") {
		t.Error("拉丁字母多于汉字的混排行:当前口径是判成需要翻(见上面注释)")
	}
}

func TestTranslationSkipsCreditLinesButKeepsSpeakerLines(t *testing.T) {
	lyrics := "[00:00.00] 作词 : 孙仪\n" +
		"[00:02.00] 编曲 : Edward Chan/方大同\n" +
		"[00:16.73]你问我爱你有多深\n" +
		"[01:02.00]It represent my heart!\n" +
		"[01:06.00]男：It represent my heart!\n" +
		"[01:10.00]女：你问我爱你有多深\n"
	speakers := lyricSpeakerLabels(lyrics)
	if !speakers["男"] || !speakers["女"] {
		t.Fatalf("前置条件:应认出男/女两个说话人标签,实际 %v", speakers)
	}
	type want struct {
		text string
		send bool
	}
	cases := []want{
		{"作词 : 孙仪", false},
		{"编曲 : Edward Chan/方大同", false},
		{"你问我爱你有多深", false},
		{"It represent my heart!", true},
		{"男：It represent my heart!", true},
		{"女：你问我爱你有多深", false},
	}
	for _, c := range cases {
		isCredit := isCreditLineWithSpeakers(c.text, speakers)
		needs := lineNeedsTranslation(c.text, "zh-CN")
		got := !isCredit && needs
		if got != c.send {
			t.Errorf("%q: 送翻=%v(credit=%v needs=%v), 期望 %v",
				c.text, got, isCredit, needs, c.send)
		}
	}
}

func TestMyMemoryLangCode(t *testing.T) {
	cases := map[string]string{
		"zh": "zh-CN", "zh-Hans": "zh-CN", "ZH-CN": "zh-CN",
		"zh-Hant": "zh-TW", "zh-TW": "zh-TW",
		"en": "en", "ja": "ja", "": "",
	}
	for in, want := range cases {
		if got := myMemoryLangCode(in); got != want {
			t.Errorf("myMemoryLangCode(%q) = %q, want %q", in, got, want)
		}
	}
}

func fakeMyMemory(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return srv
}

func TestTranslateChunkLineCountMismatchFallsBackToSource(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {

		fmt.Fprint(w, `{"responseData":{"translatedText":"一\n二"},"responseStatus":200}`)
	})
	hc := srv.Client()
	lrc := "[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	res, err := machineTranslateLRCWithBase(context.Background(), hc, srv.URL, lrc, "zh-CN")
	if err != nil {
		t.Fatal(err)
	}

	if res.lrc != "" {
		t.Errorf("行数对不上时应该没有译文,实际得到:\n%s", res.lrc)
	}
}

func TestTranslateDedupesRepeatedLinesAndBroadcastsResult(t *testing.T) {
	var requestedLines []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		requestedLines = append(requestedLines, lines...)
		out := make([]string, len(lines))
		for i, l := range lines {
			switch l {
			case "Just beat it":
				out[i] = "打败它"
			case "No one wants to be defeated":
				out[i] = "没人想被打败"
			default:
				t.Fatalf("意料之外的请求行: %q", l)
			}
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	lrc := "[00:01.00]Just beat it\n" +
		"[00:02.00]Just beat it\n" +
		"[00:03.00]No one wants to be defeated\n" +
		"[00:04.00]Just beat it"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "zh-CN")
	if err != nil {
		t.Fatal(err)
	}

	if len(requestedLines) != 2 {
		t.Fatalf("请求行数 = %d,应该去重成 2(3 次 Just beat it 只应该发一次): %v",
			len(requestedLines), requestedLines)
	}
	want := "[00:01.00]打败它\n[00:02.00]打败它\n[00:03.00]没人想被打败\n[00:04.00]打败它"
	if res.lrc != want {
		t.Errorf("译文没有广播到全部重复出现的位置:\n得到 %q\n期望 %q", res.lrc, want)
	}
}

func TestTranslateRejectsSameLanguageSentinel(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"responseData":{"translatedText":"PLEASE SELECT TWO DISTINCT LANGUAGES"},"responseStatus":200}`)
	})
	_, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err == nil {
		t.Error("哨兵串应该被当成失败,而不是当译文用")
	}
}

func TestTranslateQuotaViaHTTP429(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprint(w, `{"responseData":{"translatedText":""},"responseDetails":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY. NEXT AVAILABLE IN 15 HOURS"}`)
	})
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err != nil {
		t.Fatalf("429 应该被当成配额用尽而不是错误: %v", err)
	}
	if !res.quotaReached {
		t.Error("HTTP 429 + 警告文本没有被识别成配额用尽")
	}
}

func TestTranslateQuotaFinished(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"responseData":{"translatedText":"x"},"quotaFinished":true}`)
	})
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err != nil {
		t.Fatal(err)
	}
	if !res.quotaReached {
		t.Error("配额用尽应该被报上来,让调用方整体停下而不是继续撞")
	}
}

func TestTranslateKeepsSourceTimestamps(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "译" + lines[i]
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	lrc := "[00:01.00]one\n[00:02.50]two\n[01:03.25]three"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "zh-CN")
	if err != nil {
		t.Fatal(err)
	}
	want := "[00:01.00]译one\n[00:02.50]译two\n[01:03.25]译three"
	if res.lrc != want {
		t.Errorf("译文 =\n%s\n期望 =\n%s", res.lrc, want)
	}
}

func TestNeedsTranslationBackfill(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsMachineTranslation = true
	features.LyricsTranslationLanguage = "zh"

	base := enrichEntry{Lyrics: "[00:01.00]hello world"}
	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"外语歌、没译文:补", base, true},
		{"已有社区译文:不动(社区翻译优于机翻)", func() enrichEntry { e := base; e.LyricsTr = "[00:01.00]你好"; return e }(), false},
		{"没有歌词:没得翻", enrichEntry{}, false},
		{"歌词本来就是中文:不翻(也躲开同语言哨兵)", enrichEntry{Lyrics: "[00:01.00]我们的时光"}, false},
		{"次数用尽", func() enrichEntry { e := base; e.TranslationRetryCount = translationBackfillMaxAttempts; return e }(), false},
		{"刚试过、还没到间隔", func() enrichEntry {
			e := base
			e.TranslationRetryCount = 1
			e.TranslationTS = time.Now().Unix()
			return e
		}(), false},
		{"间隔已过:再试", func() enrichEntry {
			e := base
			e.TranslationRetryCount = 1
			e.TranslationTS = time.Now().Unix() - int64(translationBackfillInterval/time.Second) - 1
			return e
		}(), true},
	}
	for _, c := range cases {
		if got := needsTranslationBackfill(c.e); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}

	features.LyricsMachineTranslation = false
	if needsTranslationBackfill(base) {
		t.Error("开关关掉时一律不翻")
	}
}

func jsonEscape(s string) (string, error) {
	b, err := json.Marshal(s)
	return string(b), err
}

func TestRandomTranslateEmailIsDistinctAndReserved(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		e := randomTranslateEmail()
		if !strings.HasSuffix(e, "@example.com") {
			t.Fatalf("域名不是保留域: %q", e)
		}
		if local := strings.TrimSuffix(e, "@example.com"); len(local) < 12 {
			t.Fatalf("本地部分太短、随机性不够: %q", e)
		}
		if seen[e] {
			t.Fatalf("第 %d 次就撞了: %q", i, e)
		}
		seen[e] = true
	}
}

func TestTranslateChunkSendsFreshEmailEachRequest(t *testing.T) {
	var got []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.URL.Query().Get("de"))
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "译" + lines[i]
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})

	var b strings.Builder
	for i := 0; i < 60; i++ {
		fmt.Fprintf(&b, "[00:%02d.00]line%d %s\n", i, i, strings.Repeat("word ", 8))
	}
	if _, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		strings.TrimRight(b.String(), "\n"), "zh-CN"); err != nil {
		t.Fatal(err)
	}
	if len(got) < 2 {
		t.Fatalf("只发了 %d 次请求,验证不了逐块换邮箱", len(got))
	}
	for i, e := range got {
		if !strings.Contains(e, "@example.com") {
			t.Fatalf("第 %d 次请求没带上邮箱: %q", i, e)
		}
	}
	for i := 1; i < len(got); i++ {
		if got[i] == got[i-1] {
			t.Fatalf("第 %d、%d 次请求用了同一个邮箱: %q", i-1, i, got[i])
		}
	}
}

func TestTranslationUsableRespectsLanguage(t *testing.T) {
	cases := []struct {
		name   string
		e      enrichEntry
		target string
		want   bool
	}{
		{"没有译文", enrichEntry{}, "zh-CN", false},

		{"网易云中文译文 + 目标中文:用得上",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh"}, "zh-CN", true},
		{"网易云中文译文 + 目标日语:用不上,该重翻",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh"}, "ja", false},
		{"Musixmatch 日语译文 + 目标日语:用得上",
			enrichEntry{LyricsTr: "[00:01.00]こんにちは", LyricsTrLang: "ja"}, "ja", true},
		{"Musixmatch 日语译文 + 目标改成了中文:用不上",
			enrichEntry{LyricsTr: "[00:01.00]こんにちは", LyricsTrLang: "ja"}, "zh-CN", false},
		{"简繁也算不同语言",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh-Hans"}, "zh-TW", false},

		{"老条目中文译文 + 目标中文:用得上",
			enrichEntry{LyricsTr: "[00:01.00]我们的时光"}, "zh-CN", true},
		{"老条目中文译文 + 目标日语:看得出是中文,用不上",
			enrichEntry{LyricsTr: "[00:01.00]我们的时光"}, "ja", false},
		{"老条目非中文译文 + 目标日语:判不出,保守留着不重翻",
			enrichEntry{LyricsTr: "[00:01.00]Hello there"}, "ja", true},
		{"老条目非中文译文 + 目标中文:显然用不上",
			enrichEntry{LyricsTr: "[00:01.00]Hello there"}, "zh-CN", false},
	}
	for _, c := range cases {
		if got := translationUsable(c.e, c.target); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestNeedsTranslationBackfillIgnoresWrongLanguageTranslation(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsMachineTranslation = true

	base := enrichEntry{
		Lyrics:       "[00:01.00]The painful youth I've had",
		LyricsTr:     "[00:01.00]我经历过的痛苦的青春",
		LyricsTrLang: "zh",
	}

	features.LyricsTranslationLanguage = "zh"
	if needsTranslationBackfill(base) {
		t.Error("目标是中文、已有中文译文时不该再翻一遍")
	}

	features.LyricsTranslationLanguage = "ja"
	if !needsTranslationBackfill(base) {
		t.Error("目标是日语、只有中文译文时必须让机翻接手 —— 这正是这次要修的")
	}
}

func TestNeedsTranslationBackfillResetsAttemptsOnLanguageChange(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsMachineTranslation = true
	features.LyricsTranslationLanguage = "ja"

	e := enrichEntry{
		Lyrics:                "[00:01.00]The painful youth I've had",
		TranslationRetryCount: translationBackfillMaxAttempts,
		TranslationTS:         time.Now().Unix(),
	}

	e.TranslationLang = "ja"
	if needsTranslationBackfill(e) {
		t.Error("同一个目标语言下次数用尽就该停手")
	}

	e.TranslationLang = "zh-CN"
	if !needsTranslationBackfill(e) {
		t.Error("换到日语后应该重新开始尝试,而不是背着中文那轮的失败次数")
	}

	e.TranslationLang = ""
	if needsTranslationBackfill(e) {
		t.Error("老条目不该因为没记语言就绕过次数上限")
	}
}

func TestBackfillTranslationPersistsToDisk(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "译" + lines[i]
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})

	savedFeatures, savedCache, savedPath, savedBase, savedDir, savedClient :=
		features, enrichCache, enrichPath, translateBaseURL, lyricsDir, translateClient
	defer func() {
		features, enrichCache, enrichPath, translateBaseURL, lyricsDir, translateClient =
			savedFeatures, savedCache, savedPath, savedBase, savedDir, savedClient
	}()

	features.LyricsMachineTranslation = true
	features.LyricsTranslationLanguage = "zh"
	translateBaseURL = srv.URL
	translateClient = srv.Client()
	lyricsDir = ""
	enrichPath = filepath.Join(t.TempDir(), "enrich-cache.json")

	const key = "Someone|Some Song|Some Album"
	enrichCache = map[string]enrichEntry{
		key: {Lyrics: "[00:01.00]The painful youth\n[00:02.00]I have had"},
	}
	enrichInflight = map[string]bool{key: true}

	backfillTranslation(context.Background(), key)

	raw, err := os.ReadFile(enrichPath)
	if err != nil {
		t.Fatalf("缓存根本没写到磁盘: %v", err)
	}
	var onDisk map[string]enrichEntry
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatal(err)
	}
	got := onDisk[key]
	if got.LyricsTr == "" {
		t.Fatal("译文没有落盘 —— App 读的是这个文件,界面上就会一直没有翻译")
	}
	if got.LyricsTrLang != "zh-CN" {
		t.Errorf("落盘的译文语言 = %q, 期望 zh-CN", got.LyricsTrLang)
	}
	if got.LyricsTrSource != lyricsTrSourceMachine {
		t.Errorf("落盘的译文来源 = %q, 期望 %q", got.LyricsTrSource, lyricsTrSourceMachine)
	}
}

func TestTranslationUsableDistrustsLangLabelContradictedByText(t *testing.T) {
	const chineseTr = "[00:10.00]虽然觉得\n[00:12.00]不会有恋慕的眼神\n[00:15.00]如此幸运的邂逅\n"
	const englishTr = "[00:10.00]Even though I thought\n[00:12.00]no one would look at me\n[00:15.00]such luck\n"

	cases := []struct {
		label  string
		lang   string
		tr     string
		target string
		want   bool
	}{
		{"标签 en 但正文是中文 → 不算数(用户实报的那条)", "en", chineseTr, "en", false},
		{"同上,目标是中文 → 反而算数", "en", chineseTr, "zh-CN", true},
		{"标签 en、正文确实是英文 → 照旧算数", "en", englishTr, "en", true},
		{"标签 zh、正文中文、目标中文 → 算数", "zh", chineseTr, "zh-CN", true},
		{"标签 zh、正文中文、目标英文 → 不算数", "zh", chineseTr, "en", false},
		{"没有标签、正文中文、目标英文 → 不算数", "", chineseTr, "en", false},
		{"没有标签、正文英文、目标英文 → 保守当作算数", "", englishTr, "en", true},
		{"压根没有译文", "en", "", "en", false},
	}
	for _, c := range cases {
		e := enrichEntry{LyricsTr: c.tr, LyricsTrLang: c.lang}
		if got := translationUsable(e, c.target); got != c.want {
			t.Errorf("%s: translationUsable(lang=%q, target=%q) = %v, want %v",
				c.label, c.lang, c.target, got, c.want)
		}
	}
}

func TestDominantScriptAndLineNeeds(t *testing.T) {
	cases := []struct {
		text   string
		target string
		need   bool
		label  string
	}{
		{"最後のキスは", "en", true, "日文行 → 要翻成英文"},
		{"You are always gonna be my love", "en", false, "英文行 → 目标就是英文,不用翻"},
		{"タバコのflavorがした", "en", true, "日英混在一行,假名占优 → 仍是日文行"},
		{"我爱你", "en", true, "中文行 → 要翻"},
		{"I love you", "zh", true, "英文行 → 要翻成中文"},
		{"我爱你", "zh", false, "中文行 → 目标就是中文,不用翻"},
		{"最後のキスは", "ja", false, "日文行 → 目标是日文,不用翻"},
		{"사랑해", "en", true, "韩文行 → 要翻"},
		{"♪♪♪", "en", false, "没有文字,没什么可翻"},
		{"", "en", false, "空行"},
	}
	for _, c := range cases {
		if got := lineNeedsTranslation(c.text, c.target); got != c.need {
			t.Errorf("%s: lineNeedsTranslation(%q, %q) = %v, want %v",
				c.label, c.text, c.target, got, c.need)
		}
	}

	if dominantScript("明日の今頃には") != scriptKana {
		t.Error("含假名的日文行该判成假名档,不该被汉字数量盖过去")
	}
}

func TestMixedLanguageLyricsOnlySendsForeignLines(t *testing.T) {
	var sent []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		sent = append(sent, q)
		lines := strings.Split(q, "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "TRANSLATED"
		}
		fmt.Fprintf(w, `{"responseData":{"translatedText":%q},"responseStatus":200}`,
			strings.Join(out, "\n"))
	})

	lrc := "[00:01.00]最後のキスは\n[00:02.00]タバコのflavorがした\n" +
		"[00:03.00]You are always gonna be my love\n[00:04.00]I'll remember to love\n" +
		"[00:05.00]明日の今頃には"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "en")
	if err != nil {
		t.Fatalf("不该报错: %v", err)
	}
	if res.lrc == "" {
		t.Fatal("该产出译文,实际是空的 —— 正是用户报的症状")
	}
	body := strings.Join(sent, "\n")
	for _, eng := range []string{"You are always gonna be my love", "I'll remember to love"} {
		if strings.Contains(body, eng) {
			t.Errorf("英文行不该被发去翻译,却出现在请求里: %q", eng)
		}
	}
	for _, jp := range []string{"最後のキスは", "明日の今頃には"} {
		if !strings.Contains(body, jp) {
			t.Errorf("日文行必须被发去翻译,却没出现在请求里: %q", jp)
		}
	}

	if strings.Contains(res.lrc, "00:03") || strings.Contains(res.lrc, "00:04") {
		t.Errorf("英文行不该出现在译文 LRC 里:\n%s", res.lrc)
	}
	for _, tag := range []string{"[00:01.00]", "[00:02.00]", "[00:05.00]"} {
		if !strings.Contains(res.lrc, tag) {
			t.Errorf("日文行的译文该带原时间戳 %s:\n%s", tag, res.lrc)
		}
	}
}
