package main

import "testing"

func kgezhiwangBatch() []lyricCandidate {
	return []lyricCandidate{
		{source: "netease", title: "K歌之王", album: "打得火热", sourceReportedDurationSecs: 222.351},
		{source: "qq", title: "K歌之王 (粤语)", album: "打得火热", sourceReportedDurationSecs: 222, language: songLanguageCantonese, hasWordTiming: true},
		{source: "kugou", title: "K歌之王", album: "2003演唱会", sourceReportedDurationSecs: 218, language: songLanguageMandarin, hasWordTiming: true},
		{source: "migu", title: "K歌之王 AIR(Night Version)"},
	}
}

func TestInferLocalLanguageVersion(t *testing.T) {
	cases := []struct {
		name         string
		title, album string
		dur          float64
		cands        []lyricCandidate
		want         string
	}{
		{"①本地曲名带 Apple 单字缩写", "K歌之王 (國)", "2013 陈奕迅 Music Life 精选", 218.667, nil, languageVersionTagMandarin},
		{"①本地曲名带全词标签(繁体)", "K歌之王 (粵語)", "", 222.351, nil, languageVersionTagCantonese},

		{"专辑名含「国语」不算声明", "Shall We Talk", "陈奕迅 国语精选", 227.277, []lyricCandidate{
			{source: "kugou", title: "Shall We Talk", album: "Shall We Dance? Shall We Talk!", sourceReportedDurationSecs: 227, language: songLanguageCantonese},
		}, ""},
		{"②专辑精确同名+时长吻合的声明候选", "K歌之王", "打得火热", 222.351, kgezhiwangBatch(), languageVersionTagCantonese},

		{"②同专辑收了两个语种版本,声明候选时长对不上 → 不推", "To Be Or Not To Be", "To Be Or Not To Be", 188.232, []lyricCandidate{
			{source: "netease", title: "To Be Or Not To Be", album: "To Be Or Not To Be", sourceReportedDurationSecs: 188},
			{source: "kugou", title: "To Be Or Not To Be (国语)", album: "To Be Or Not To Be", sourceReportedDurationSecs: 186, language: songLanguageMandarin},
		}, ""},
		{"③两种语种都在场、自报时长能分开", "K歌之王", "七 (新歌+精选)", 222.351, []lyricCandidate{
			{source: "qq", title: "K歌之王", album: "打得火热", sourceReportedDurationSecs: 222, language: songLanguageCantonese},
			{source: "kugou", title: "K歌之王", album: "2003演唱会", sourceReportedDurationSecs: 218, language: songLanguageMandarin},
		}, languageVersionTagCantonese},
		{"③只有一种语种在场 → 不推", "K歌之王", "七 (新歌+精选)", 218.426, []lyricCandidate{
			{source: "qq", title: "K歌之王 (粤语)", album: "打得火热", sourceReportedDurationSecs: 222, language: songLanguageCantonese},
			{source: "netease", title: "K歌之王", album: "七(国语新歌+精选)", sourceReportedDurationSecs: 218.667},
		}, ""},
		{"③两版时长几乎一样 → 分不开不推", "某歌", "某专辑", 240, []lyricCandidate{
			{source: "qq", title: "某歌 (粤语)", album: "A", sourceReportedDurationSecs: 240, language: songLanguageCantonese},
			{source: "kugou", title: "某歌", album: "B", sourceReportedDurationSecs: 241, language: songLanguageMandarin},
		}, ""},
		{"没有时长时第②③步都不推", "K歌之王", "打得火热", 0, kgezhiwangBatch(), ""},
	}
	for _, c := range cases {
		if got := inferLocalLanguageVersion(c.title, c.album, c.dur, c.cands); got != c.want {
			t.Errorf("%s: inferLocalLanguageVersion = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestApplyLanguageVersionVerdicts_KGeZhiWang(t *testing.T) {
	cands := kgezhiwangBatch()
	applyLanguageVersionVerdicts("K歌之王", "打得火热", 222.351, cands)
	want := map[string][2]bool{
		"netease": {false, false},
		"qq":      {false, true},
		"kugou":   {true, false},
		"migu":    {false, false},
	}
	for _, c := range cands {
		w := want[c.source]
		if c.languageVersionMismatch != w[0] || c.languageVersionAgrees != w[1] {
			t.Errorf("%s: mismatch=%v agrees=%v, want mismatch=%v agrees=%v", c.source, c.languageVersionMismatch, c.languageVersionAgrees, w[0], w[1])
		}
	}

	byName := map[string]lyricCandidate{}
	for _, c := range cands {
		byName[c.source] = c
	}
	_, qqTerms := scoreLyricCandidateDetailed("陈奕迅", "K歌之王", "打得火热", 222.351, withLyrics(byName["qq"]), false, 2)
	if hasTerm(qqTerms, scoreTermVersionTags) {
		t.Errorf("qq「K歌之王 (粤语)」与本地同为粤语,不该吃 versionTags: %v", qqTerms)
	}
	if p := termPoints(qqTerms, scoreTermTitleMatch); p != 120 {
		t.Errorf("qq titleMatch = %d, want 120(语种标签不算版本差异)", p)
	}
	kugou := byName["kugou"]
	kugou.album = "Third Encounter Live"
	_, kugouTerms := scoreLyricCandidateDetailed("陈奕迅", "K歌之王", "打得火热", 222.351, withLyrics(kugou), false, 1)
	if !hasTerm(kugouTerms, scoreTermVersionTags) {
		t.Errorf("kugou 国语版对粤语本地,该吃 versionTags: %v", kugouTerms)
	}
	_, neteaseTerms := scoreLyricCandidateDetailed("陈奕迅", "K歌之王", "打得火热", 222.351, withLyrics(byName["netease"]), false, 2)
	if hasTerm(neteaseTerms, scoreTermVersionTags) {
		t.Errorf("netease 无任何声明,不该吃 versionTags: %v", neteaseTerms)
	}

	kugou = byName["kugou"]
	_, both := scoreLyricCandidateDetailed("陈奕迅", "K歌之王", "打得火热", 222.351, withLyrics(kugou), false, 1)
	n := 0
	for _, tm := range both {
		if tm.Kind == scoreTermVersionTags {
			n++
		}
	}
	if n != 1 {
		t.Errorf("versionTags 出现 %d 次, want 1: %v", n, both)
	}
}

func TestLanguageVersionUnknownFallsBackToV14(t *testing.T) {
	c := withLyrics(lyricCandidate{source: "kugou", title: "To Be Or Not To Be (国语)", album: "To Be Or Not To Be", sourceReportedDurationSecs: 186, language: songLanguageMandarin, hasWordTiming: true})
	_, terms := scoreLyricCandidateDetailed("张继聪", "To Be Or Not To Be", "To Be Or Not To Be", 188.232, c, false, 0)
	if !hasTerm(terms, scoreTermVersionTags) {
		t.Errorf("本地语种未知时「(国语)」标签应照 v14 判不符: %v", terms)
	}
	if p := termPoints(terms, scoreTermTitleMatch); p != 60 {
		t.Errorf("titleMatch = %d, want 60", p)
	}
}

func TestLanguageVersionTagCanonicalKeys(t *testing.T) {

	cases := []struct {
		local, cand string
		want        bool
	}{
		{"Mau U So(国)", "Mau U So (国语)", false},
		{"K歌之王 (國)", "K歌之王 (国语)", false},
		{"Song (Cantonese)", "Song (粤语)", false},
		{"K歌之王 (國語)", "K歌之王 (粵語)", true},
		{"K歌之王 (粵)", "K歌之王 (国语)", true},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.local, "", c.cand, ""); got != c.want {
			t.Errorf("versionTagsMismatch(%q, %q) = %v, want %v", c.local, c.cand, got, c.want)
		}
	}
	if !titleVersionTags("K歌之王 AIR(Night Version)")["night version"] {
		t.Errorf("AIR 重录版的 (Night Version) 应被认成版本限定词: %v", titleVersionTags("K歌之王 AIR(Night Version)"))
	}
	if got := titleVersionTags("K歌之王 AIR(Day Version)"); !got["day version"] {
		t.Errorf("(Day Version) 同理: %v", got)
	}
}

func TestCrossLanguageVersionTags(t *testing.T) {
	cases := []struct {
		name        string
		local, cand string
		want        bool
	}{
		{"英文版顶原曲(本案)", "Dried Flower", "Dried flower (English ver.)", true},
		{"本地也是英文版就不算不符", "Dried Flower (English ver.)", "Dried flower (English ver.)", false},
		{"日文版同理", "Song", "Song (Japanese ver.)", true},
		{"同一声明的不同拼法要折成一个键", "Song (日文版)", "Song (Japanese ver.)", false},

		{"中文版与国语是同一个声明", "Song (中文版)", "Song (国语)", false},
		{"中文版与粤语仍然是两个版本", "Song (中文版)", "Song (粤语)", true},
		{"两个不同语种版本", "Song (English ver.)", "Song (Japanese ver.)", true},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.local, "", c.cand, ""); got != c.want {
			t.Errorf("%s: versionTagsMismatch(%q, %q) = %v, want %v", c.name, c.local, c.cand, got, c.want)
		}
	}

	if got := declaredLanguageVersion("Dried flower (English ver.)"); got != languageVersionTagEnglish {
		t.Errorf("declaredLanguageVersion 应读出英语键, got %q", got)
	}
	if got := declaredLanguageVersion("Song (韩语版)"); got != languageVersionTagKorean {
		t.Errorf("declaredLanguageVersion 应读出韩语键, got %q", got)
	}

	if got := declaredLanguageVersion("Dried Flower"); got != "" {
		t.Errorf("没写语种版本时应返回空串, got %q", got)
	}

	tags := map[string]bool{
		languageVersionTagEnglish: true, languageVersionTagJapanese: true,
		languageVersionTagKorean: true, languageVersionTagCantonese: true,
		languageVersionTagMandarin: true, "live": true,
	}
	got := withoutLanguageVersionTags(tags)
	if len(got) != 1 || !got["live"] {
		t.Errorf("语种键应被全部摘掉、只剩 live, got %v", got)
	}
	for tag := range languageVersionTagSet {
		if got[tag] {
			t.Errorf("语种键 %q 没被摘掉", tag)
		}
	}
}

func TestLastLRCTimestampSkipsTrailingCredit(t *testing.T) {

	lrc := "[00:13.23]我唱得不够动人\n[03:14.97]而你那呵欠绝得不能绝\n[03:19.53]绝到溶掉我\n[03:39.53]监制：陈辉阳\n"
	got, ok := lastLRCTimestampSecs(lrc)
	if !ok || got != 199.53 {
		t.Errorf("lastLRCTimestampSecs = %.2f/%v, want 199.53(跳过尾部署名行)", got, ok)
	}

	duet := "[00:10.00]男：第一句\n[00:20.00]女：第二句\n[00:30.00]男：第三句\n[00:40.00]女：最后一句\n"
	if got, ok := lastLRCTimestampSecs(duet); !ok || got != 40 {
		t.Errorf("对唱末句 = %.2f/%v, want 40", got, ok)
	}

	if _, ok := lastLRCTimestampSecs("[00:00.00]作词 : 林夕\n[00:01.00]作曲 : 陈辉阳\n"); ok {
		t.Errorf("整份只有署名行,不该提出末句时间戳")
	}
}

func withLyrics(c lyricCandidate) lyricCandidate {
	c.lyrics = "[00:13.23]我唱得不够动人\n[00:16.69]你别皱眉\n[00:19.75]我愿意和你约定至死\n[00:25.41]我只想嬉戏唱游\n[03:14.97]而你那呵欠绝得不能绝\n[03:19.53]绝到溶掉我\n"
	return c
}

func termPoints(terms []scoreTerm, kind string) int {
	for _, t := range terms {
		if t.Kind == kind {
			return t.Points
		}
	}
	return 0
}
