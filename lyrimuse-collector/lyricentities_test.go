package main

import "testing"

func TestDecodeLyricEntities(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"没有 & 原样返回", "[00:32.64]普通歌词，没有实体", "[00:32.64]普通歌词，没有实体"},
		{"空串", "", ""},
		{"XML 撇号实体(酷狗真实形态)", "[00:32.64]Don&apos;t sleep &apos;til the sunrise", "[00:32.64]Don't sleep 'til the sunrise"},
		{"引号 / 与号", "[00:10.47]Carvin &quot;Ransum&quot; Haggins &amp; friends", "[00:10.47]Carvin \"Ransum\" Haggins & friends"},
		{"源自带的头部标签也解", "[ar:Earth, Wind &amp; Fire]\n[ti:Everybody (Backstreet&apos;s Back) (7&quot; Version)]", "[ar:Earth, Wind & Fire]\n[ti:Everybody (Backstreet's Back) (7\" Version)]"},
		{"十进制 / 十六进制数字实体", "it&#39;s &#x27;bout time", "it's 'bout time"},
		{"HTML 命名实体(标准库认识的都解)", "wait&hellip; &mdash; she said &lsquo;go&rsquo;", "wait… — she said ‘go’"},
		{"逐字 YRC 词条里的实体(酷狗 KRC 转出来的形态)", "[33581,1060](33581,1060,0)&apos;til (34641,310,0)the", "[33581,1060](33581,1060,0)'til (34641,310,0)the"},

		{"不带分号的遗留实体不碰(Q&A / R&B / &notice)", "Q&A at the R&B show, take &notice", "Q&A at the R&B show, take &notice"},
		{"不认识的实体名原样保留", "R&B; and &foo; and &x1;", "R&B; and &foo; and &x1;"},
		{"控制字符不换(&#10; 会拆行)", "line one&#10;line two &#9;tab", "line one&#10;line two &#9;tab"},
		{"nbsp 换成普通空格而不是 U+00A0", "Whoa&nbsp;? and&#160;this&#xa0;too", "Whoa ? and this too"},

		{"双重转义只解一层", "they&amp;apos;re", "they&apos;re"},
		{"孤立的 & 原样", "rock & roll & more &", "rock & roll & more &"},
		{"实体名过长不匹配", "&" + "abcdefghijklmnopqrstuvwxyzabcdefghij;", "&abcdefghijklmnopqrstuvwxyzabcdefghij;"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := decodeLyricEntities(c.in); got != c.want {
				t.Errorf("decodeLyricEntities(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestDecodeLyricEntitiesIdempotentOnCleanText(t *testing.T) {
	clean := decodeLyricEntities("[00:32.64]Don&apos;t sleep &apos;til the sunrise &amp; Carvin &quot;Ransum&quot;")
	if again := decodeLyricEntities(clean); again != clean {
		t.Errorf("second pass changed clean text: %q -> %q", clean, again)
	}
}

func TestDecodeLyricSourceEntitiesCoversEveryTextFieldAndLeavesInputAlone(t *testing.T) {
	raw := map[string]lyricSourceResult{
		"kugou":   {source: "kugou", lyr: "[00:01.00]Don&apos;t", yrc: "[1000,500](1000,500,0)Don&apos;t", tr: "[00:01.00]译&amp;文", roma: "[00:01.00]don&apos;t", matchTitle: "Don&apos;t Stop"},
		"netease": {source: "netease", ne: neteaseInfo{Lyrics: "[00:01.00]Whoa&nbsp;?", Trans: "[00:01.00]哇&quot;", Roma: "[00:01.00]wo&apos;a", YRC: "[1000,500](1000,500,0)Whoa&nbsp;?"}},
		"amll":    {source: "amll", amll: amllResult{lrc: "[00:01.00]it&apos;s", yrc: "[1000,500](1000,500,0)it&apos;s", tr: "[00:01.00]它&amp;"}},
	}
	out := decodeLyricSourceEntities(raw)

	k := out["kugou"]
	if k.lyr != "[00:01.00]Don't" || k.yrc != "[1000,500](1000,500,0)Don't" || k.tr != "[00:01.00]译&文" || k.roma != "[00:01.00]don't" {
		t.Errorf("kugou fields not decoded: %+v", k)
	}
	if k.matchTitle != "Don&apos;t Stop" {
		t.Errorf("matchTitle must be left alone (it feeds title matching), got %q", k.matchTitle)
	}
	n := out["netease"].ne
	if n.Lyrics != "[00:01.00]Whoa ?" || n.Trans != "[00:01.00]哇\"" || n.Roma != "[00:01.00]wo'a" || n.YRC != "[1000,500](1000,500,0)Whoa ?" {
		t.Errorf("netease fields not decoded: %+v", n)
	}
	a := out["amll"].amll
	if a.lrc != "[00:01.00]it's" || a.yrc != "[1000,500](1000,500,0)it's" || a.tr != "[00:01.00]它&" {
		t.Errorf("amll fields not decoded: %+v", a)
	}

	if raw["kugou"].lyr != "[00:01.00]Don&apos;t" || raw["netease"].ne.Lyrics != "[00:01.00]Whoa&nbsp;?" || raw["amll"].amll.lrc != "[00:01.00]it&apos;s" {
		t.Errorf("input map was mutated: %+v", raw)
	}

	if again := decodeLyricSourceEntities(raw); again["kugou"].lyr != out["kugou"].lyr {
		t.Errorf("re-running rank over the same raw changed the result: %q vs %q", again["kugou"].lyr, out["kugou"].lyr)
	}
}

func TestMigrateLyricEntities(t *testing.T) {
	enrichMu.Lock()
	savedCache, savedDirty, savedPath := enrichCache, enrichDirty, enrichPath
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache, enrichDirty, enrichPath = savedCache, savedDirty, savedPath
		enrichMu.Unlock()
	})

	dirtyLyrics := "[00:32.64]Don&apos;t sleep &apos;til the sunrise\n[00:39.19]Don&apos;t worry"
	cleanLyrics := "[00:32.64]Don't sleep 'til the sunrise\n[00:39.19]Don't worry"
	enrichMu.Lock()
	enrichPath = ""
	enrichDirty = false
	enrichCache = map[string]enrichEntry{
		"kugou-matching-sha": {
			Lyrics: dirtyLyrics, LyricsYRC: "[32640,1000](32640,1000,0)Don&apos;t", LyricsTr: "[00:32.64]译&amp;文",
			LyricsRoma: "[00:32.64]don&apos;t", PlainLyrics: "Don&apos;t",
			ManualPickSHA: manualPickFingerprint(dirtyLyrics), ManualLyrics: true,
		},
		"kugou-stale-sha": {Lyrics: dirtyLyrics, ManualPickSHA: "000000000000"},
		"clean":           {Lyrics: "[00:01.00]rock & roll", LyricsYRC: "[1000,500](1000,500,0)rock & roll", ManualPickSHA: "abcdefabcdef"},
	}
	enrichMu.Unlock()

	migrateLyricEntities()

	enrichMu.Lock()
	defer enrichMu.Unlock()
	e := enrichCache["kugou-matching-sha"]
	if e.Lyrics != cleanLyrics || e.LyricsYRC != "[32640,1000](32640,1000,0)Don't" || e.LyricsTr != "[00:32.64]译&文" || e.LyricsRoma != "[00:32.64]don't" || e.PlainLyrics != "Don't" {
		t.Errorf("fields not decoded: %+v", e)
	}
	if !e.ManualLyrics {
		t.Errorf("manual_lyrics flag must survive")
	}
	if e.ManualPickSHA != manualPickFingerprint(cleanLyrics) {
		t.Errorf("manual_pick_sha must be recomputed on the decoded text: got %q want %q", e.ManualPickSHA, manualPickFingerprint(cleanLyrics))
	}
	if s := enrichCache["kugou-stale-sha"]; s.Lyrics != cleanLyrics || s.ManualPickSHA != "000000000000" {
		t.Errorf("stale sha must be left alone while text is still decoded: %+v", s)
	}
	if c := enrichCache["clean"]; c.Lyrics != "[00:01.00]rock & roll" || c.LyricsYRC != "[1000,500](1000,500,0)rock & roll" || c.ManualPickSHA != "abcdefabcdef" {
		t.Errorf("clean entry must be untouched: %+v", c)
	}
	if !enrichDirty {
		t.Errorf("migration changed entries but did not mark the cache dirty")
	}

	enrichDirty = false
	enrichMu.Unlock()
	migrateLyricEntities()
	enrichMu.Lock()
	if enrichDirty {
		t.Errorf("second run must be a no-op")
	}
}
