package main

import (
	"reflect"
	"testing"
)

func TestNormEnrichTitle(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{

		{"全角括号译名", "不散的筵席（I Miss You）", "不散的筵席"},
		{"全角括号译名2", "神探（The Detective）", "神探"},
		{"半角括号译名", "小師妹 (Love Triangle)", "小師妹"},

		{"remix 保留", "Song (Remix)", "Song (Remix)"},
		{"live 保留", "告白气球 (Live)", "告白气球 (Live)"},
		{"remaster 保留", "Bad (2012 Remaster)", "Bad (2012 Remaster)"},
		{"feat 保留", "爱我的人 (feat. MOE.)", "爱我的人 (feat. MOE.)"},
		{"instrumental 保留", "Song (Instrumental)", "Song (Instrumental)"},

		{"interlude 保留", "The Girl In Red (Interlude)", "The Girl In Red (Interlude)"},
		{"中文版本标记保留", "月亮代表我的心 (现场版)", "月亮代表我的心 (现场版)"},

		{"慢板保留", "Secret (慢板)", "Secret (慢板)"},
		{"快板保留", "第二圆舞曲 (快板)", "第二圆舞曲 (快板)"},

		{"括号就是整个歌名", "(Interlude)", "(Interlude)"},
		{"括号就是整个歌名2", "（前奏）", "（前奏）"},
		{"两层括号连剥", "歌名（译名）[Explicit]", "歌名"},
		{"剥到版本标记停手", "歌名（译名）(Live)", "歌名（译名）(Live)"},
		{"中间的括号不动", "Song (A) tail", "Song (A) tail"},
		{"没有括号", "不散的筵席", "不散的筵席"},
		{"空串", "", ""},

		{"不换行空格", "Song\u00a0(I Miss You)", "Song"},
		{"零宽字符", "不散\u200b的筵席", "不散的筵席"},
		{"全角空格", "不散的筵席\u3000（I Miss You）", "不散的筵席"},
	}
	for _, c := range cases {
		if got := normEnrichTitle(c.in); got != c.want {
			t.Errorf("%s: normEnrichTitle(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestEnrichKeyDoesNotFoldCaseOrScript(t *testing.T) {

	got := enrichKey("PRINCE", "The Girl In Red (Interlude)", "神經志 The Journal")
	want := "PRINCE|The Girl In Red (Interlude)|神經志 The Journal"
	if got != want {
		t.Errorf("enrichKey = %q, want %q", got, want)
	}
}

func TestEnrichKeyIsIdempotent(t *testing.T) {

	for _, in := range []string{
		"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal",
		"Prince|Song (Remix)|3121",
	} {
		a, ti, al := splitEnrichKey(in)
		once := enrichKey(a, ti, al)
		a2, ti2, al2 := splitEnrichKey(once)
		if twice := enrichKey(a2, ti2, al2); twice != once {
			t.Errorf("not idempotent: %q -> %q -> %q", in, once, twice)
		}
	}
}

func TestPlanEnrichKeyMigrationGroups(t *testing.T) {
	cache := map[string]enrichEntry{
		"丁世光|不散的筵席|神經志 The Journal":                       {LyricsSource: "netease"},
		"丁世光|不散的筵席（I Miss You）|神經志 The Journal":           {LyricsSource: "kugou"},
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal": {LyricsSource: "qq"},
	}
	got := planEnrichKeyMigration(cache)
	want := map[string][]string{
		"丁世光|不散的筵席|神經志 The Journal": {
			"丁世光|不散的筵席|神經志 The Journal",
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
		},
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal": {
			"丁世光|The Girl In Red (Interlude)|神經志 The Journal",
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("planEnrichKeyMigration = %#v, want %#v", got, want)
	}
}

func TestPlanEnrichKeyMigrationDurationGuard(t *testing.T) {

	t.Run("时长差太多不合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"某人|神探（Sherlock）|专辑":      {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 68},
			"某人|神探（The Detective）|专辑": {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"某人|神探|专辑":                {"某人|神探（Sherlock）|专辑"},
			"某人|神探（The Detective）|专辑": {"某人|神探（The Detective）|专辑"},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want %#v", got, want)
		}
	})

	t.Run("时长接近正常合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":             {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 258},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"丁世光|不散的筵席|神經志 The Journal": {
				"丁世光|不散的筵席|神經志 The Journal",
				"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
			},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want merged: %#v", got, want)
		}
	})

	t.Run("时长未知不拦合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":             {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 0},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		if len(got) != 1 {
			t.Errorf("want 1 merged group when one side has unknown duration, got %#v", got)
		}
	})

	t.Run("nk名字冲突时整组放弃合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":             {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 68},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"丁世光|不散的筵席|神經志 The Journal":             {"丁世光|不散的筵席|神經志 The Journal"},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {"丁世光|不散的筵席（I Miss You）|神經志 The Journal"},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want both kept standalone: %#v", got, want)
		}
	})
}

func TestEnrichKeyDurationVariant(t *testing.T) {
	got := enrichKeyDurationVariant("周杰倫|Secret|不能說的秘密 電影原聲帶", 2)
	want := "周杰倫|Secret~dur2|不能說的秘密 電影原聲帶"
	if got != want {
		t.Errorf("enrichKeyDurationVariant = %q, want %q", got, want)
	}

	if artist, _, album := splitEnrichKey(got); artist != "周杰倫" || album != "不能說的秘密 電影原聲帶" {
		t.Errorf("variant polluted artist/album: artist=%q album=%q", artist, album)
	}
}

func TestResolveEnrichKeyForDuration(t *testing.T) {
	key := "周杰倫|Secret|不能說的秘密 電影原聲帶"

	t.Run("key不存在直接放行", func(t *testing.T) {
		cache := map[string]enrichEntry{}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 231)
		if rk != key || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, key)
		}
	})

	t.Run("时长兼容直接复用原key", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		rk, e, ok := resolveEnrichKeyForDuration(cache, key, 233)
		if rk != key || !ok || e.LyricsScore != 1200 {
			t.Errorf("got (%q, %+v, ok=%v), want reuse of %q", rk, e, ok, key)
		}
	})

	t.Run("任一方时长未知也当兼容", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 0}}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != key || !ok {
			t.Errorf("got (%q, ok=%v), want reuse of %q (unknown duration must not block)", rk, ok, key)
		}
	})

	t.Run("时长冲突且无变体位_落到第一个空位新建", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		want := enrichKeyDurationVariant(key, 2)
		if rk != want || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, want)
		}
	})

	t.Run("变体位已存在且时长兼容_复用它", func(t *testing.T) {
		v2 := enrichKeyDurationVariant(key, 2)
		cache := map[string]enrichEntry{
			key: {LyricsScore: 1200, DurationSecs: 231},
			v2:  {LyricsScore: 900, DurationSecs: 68},
		}
		rk, e, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != v2 || !ok || e.LyricsScore != 900 {
			t.Errorf("got (%q, %+v, ok=%v), want reuse of %q", rk, e, ok, v2)
		}
	})

	t.Run("变体位存在但也冲突_跳到下一个空位", func(t *testing.T) {
		v2 := enrichKeyDurationVariant(key, 2)
		cache := map[string]enrichEntry{
			key: {LyricsScore: 1200, DurationSecs: 231},
			v2:  {LyricsScore: 900, DurationSecs: 400},
		}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		want := enrichKeyDurationVariant(key, 3)
		if rk != want || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, want)
		}
	})

	t.Run("变体位全部冲突_放弃消歧退回原key", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		for n := 2; n <= maxEnrichKeyDurationVariants; n++ {
			cache[enrichKeyDurationVariant(key, n)] = enrichEntry{DurationSecs: float64(n) * 500}
		}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != key || !ok {
			t.Errorf("got (%q, ok=%v), want fallback to (%q, ok=true)", rk, ok, key)
		}
	})
}

func TestBetterEnrichEntry(t *testing.T) {
	manual := enrichEntry{ManualLyrics: true, Lyrics: "x", LyricsScore: 1}
	high := enrichEntry{Lyrics: "x", LyricsScore: 1203}
	low := enrichEntry{Lyrics: "x", LyricsScore: 1107}
	empty := enrichEntry{LyricsScore: 9999}

	if !betterEnrichEntry(manual, high, "a", "b") {
		t.Error("manual entry must win over a higher-scored automatic one")
	}

	if !betterEnrichEntry(low, empty, "a", "b") {
		t.Error("entry with lyrics must win over an empty one")
	}

	if !betterEnrichEntry(high, low, "a", "b") {
		t.Error("higher lyrics_score must win")
	}

	same := enrichEntry{Lyrics: "x", LyricsScore: 5, TS: 7}
	if !betterEnrichEntry(same, same, "a", "b") || betterEnrichEntry(same, same, "b", "a") {
		t.Error("ties must break deterministically on key order")
	}
}

func TestMergePeripheralIntoKeepsLyricsBundleIntact(t *testing.T) {
	winner := enrichEntry{Lyrics: "winner lyrics", LyricsSource: "kugou", LyricsScore: 1203}
	loser := enrichEntry{
		Lyrics: "loser lyrics", LyricsTr: "loser translation", LyricsYRC: "loser yrc",
		LyricsSource: "netease", LyricsScore: 1107,
		CoverURL: "https://cover", CoverSource: "netease", AccentColor: "#123456",
		NeteaseURL: "https://ne", CanonicalArtist: "丁世光", DurationSecs: 261,
	}
	got := mergePeripheralInto(winner, loser)

	if got.CoverURL != "https://cover" || got.CoverSource != "netease" ||
		got.AccentColor != "#123456" || got.NeteaseURL != "https://ne" ||
		got.CanonicalArtist != "丁世光" || got.DurationSecs != 261 {
		t.Errorf("peripheral fields not filled from loser: %#v", got)
	}

	if got.Lyrics != "winner lyrics" || got.LyricsSource != "kugou" || got.LyricsScore != 1203 {
		t.Errorf("winner's lyrics identity was overwritten: %#v", got)
	}
	if got.LyricsTr != "" || got.LyricsYRC != "" {
		t.Errorf("loser's lyric variants leaked onto the winner: tr=%q yrc=%q", got.LyricsTr, got.LyricsYRC)
	}
}

func TestStaleExportKeysAlwaysDropsLosers(t *testing.T) {
	plain := "丁世光|不散的筵席|神經志 The Journal"
	subtitled := "丁世光|不散的筵席（I Miss You）|神經志 The Journal"
	olds := []string{plain, subtitled}

	got := staleExportKeys(plain, subtitled, olds)
	want := map[string]bool{plain: true, subtitled: true}
	if len(got) != 2 {
		t.Fatalf("want both keys stale (loser's file must go even though it already has the final name), got %v", got)
	}
	for _, k := range got {
		if !want[k] {
			t.Errorf("unexpected stale key %q", k)
		}
	}

	got = staleExportKeys(plain, plain, olds)
	if len(got) != 1 || got[0] != subtitled {
		t.Errorf("want only the loser stale, got %v", got)
	}

	got = staleExportKeys(plain, subtitled, []string{subtitled})
	if len(got) != 1 || got[0] != subtitled {
		t.Errorf("rename case should mark the old name stale, got %v", got)
	}

	if got = staleExportKeys(plain, plain, []string{plain}); len(got) != 0 {
		t.Errorf("no-op case should mark nothing stale, got %v", got)
	}
}

func TestEnrichExportedFileNamesCoversBothForms(t *testing.T) {

	names := enrichExportedFileNames("丁世光|不散的筵席|神經志 The Journal")
	if len(names) != 8 {
		t.Fatalf("want 8 candidate names, got %d: %v", len(names), names)
	}
	var plain, hashed int
	for _, n := range names {
		if n == "丁世光 - 不散的筵席 - 神經志 The Journal.lrc" {
			plain++
		}
		if len(n) > 0 && n[len(n)-4:] == ".lrc" && containsTilde(n) {
			hashed++
		}
	}
	if plain != 1 {
		t.Errorf("plain .lrc name missing from %v", names)
	}
	if hashed == 0 {
		t.Errorf("hashed .lrc name missing from %v", names)
	}
}

func containsTilde(s string) bool {
	for _, r := range s {
		if r == '~' {
			return true
		}
	}
	return false
}
