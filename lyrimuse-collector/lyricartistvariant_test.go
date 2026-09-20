package main

import "testing"

func TestLyricSourceArtistMatches(t *testing.T) {
	cases := []struct {
		candidate, query string
		want             bool
	}{

		{"UMI、V", "UMI & 金泰亨", true},
		{"UMI/V", "UMI & 金泰亨", true},
		{"UMI, V", "UMI & 金泰亨", true},

		{"UMI、V", "UMI & V", true},

		{"UMI/V", "UMI", true},
		{"UMI", "UMI & 金泰亨", true},

		{"umi & 金泰亨", "UMI & 金泰亨", true},

		{"周杰伦、", "周杰伦 & 王力宏", false},
		{"周杰伦、", "周杰伦", false},

		{"周杰伦-", "周杰伦 & 王力宏", false},

		{"周杰倫", "周杰伦", true},

		{"周杰倫-", "周杰伦", false},

		{"丁世光(Dean Ting)", "丁世光", true},

		{"anna & bob", "an & bobby", false},

		{"", "UMI & 金泰亨", false},
		{"UMI、V", "", false},
	}
	for _, c := range cases {
		if got := lyricSourceArtistMatches(c.candidate, c.query); got != c.want {
			t.Errorf("lyricSourceArtistMatches(%q, %q) = %v, want %v", c.candidate, c.query, got, c.want)
		}
	}
}

func TestLyricPrimaryQueryArtist(t *testing.T) {
	cases := []struct {
		artist, want string
	}{
		{"UMI & 金泰亨", "UMI"},
		{"陶喆、卢广仲", "陶喆"},
		{"Prince & The Revolution", "Prince"},

		{"UMI feat. V", "UMI"},
		{"UMI ft V", "UMI"},
		{"IU (feat. SUGA)", "IU"},
		{"IU（feat. SUGA）", "IU"},
		{"Beyoncé featuring Jay-Z", "Beyoncé"},

		{"Taylor Swift", ""},
		{"周杰伦", ""},
		{"", ""},

		{"周杰伦、", ""},

		{"Sleeping With Sirens", ""},
		{"Charli xcx", ""},

		{"Softest Hard", ""},

		{"FT Island", ""},

		{"K/DA", ""},

		{"K/DA/Madison Beer/(G)I-DLE/Jaira Burns", "K/DA"},
	}
	for _, c := range cases {
		if got := lyricPrimaryQueryArtist(c.artist); got != c.want {
			t.Errorf("lyricPrimaryQueryArtist(%q) = %q, want %q", c.artist, got, c.want)
		}
	}
}

func TestUsableLyricSourceCount(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 462},
		{Source: "netease", Score: 52},
		{Source: "qq", Score: -1},
		{Source: "kugou", Score: 0},
		{Source: "lrclib", Score: -1, Instrumental: true},
	}
	if got := usableLyricSourceCount(scored); got != 2 {
		t.Errorf("usableLyricSourceCount = %d, want 2", got)
	}
	if got := usableLyricSourceCount(nil); got != 0 {
		t.Errorf("usableLyricSourceCount(nil) = %d, want 0", got)
	}
}

func TestMergeLyricCandidateRounds(t *testing.T) {
	timed := "[00:01.00] line one\n[00:05.00] line two\n[00:09.00] line three"
	timedAlt := "[00:01.20] line one\n[00:05.10] line two\n[00:09.30] line three"
	base := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: timed, Score: 400, Title: "base-netease"},
		{Source: "qq", Lyrics: "no timestamps here", Score: -1, Title: "base-qq-rejected"},
		{Source: "lrclib", Score: -1, Instrumental: true},
	}
	extra := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: timedAlt, Score: 999, Title: "extra-netease"},
		{Source: "qq", Lyrics: timedAlt, Score: 300, Title: "extra-qq"},
		{Source: "kugou", Lyrics: timed, Score: 500, Title: "extra-kugou"},
	}
	merged := mergeLyricCandidateRounds("someone & 别人", "song", "album", 0, base, extra)

	bySource := map[string]scoredLyricCandidateResult{}
	instrumentalKept := false
	for _, r := range merged {
		if r.Instrumental {
			instrumentalKept = true
			continue
		}
		if _, dup := bySource[r.Source]; dup {
			t.Errorf("merge produced duplicate source %q", r.Source)
		}
		bySource[r.Source] = r
	}

	if got := bySource["netease"].Title; got != "base-netease" {
		t.Errorf("netease candidate = %q, want base round's (base-netease)", got)
	}

	if got := bySource["qq"].Title; got != "extra-qq" {
		t.Errorf("qq candidate = %q, want extra round's (extra-qq)", got)
	}

	if _, ok := bySource["kugou"]; !ok {
		t.Errorf("kugou candidate from variant round missing")
	}

	for _, s := range []string{"netease", "qq", "kugou"} {
		if bySource[s].Score < 0 {
			t.Errorf("%s rescored to %d, want >= 0", s, bySource[s].Score)
		}
		if len(bySource[s].ScoreTerms) == 0 {
			t.Errorf("%s missing rescored ScoreTerms", s)
		}
	}

	if !instrumentalKept {
		t.Errorf("lrclib instrumental marker dropped, want kept")
	}

	for i := 1; i < len(merged); i++ {
		if merged[i-1].Score < merged[i].Score {
			t.Errorf("merged not sorted: %d before %d", merged[i-1].Score, merged[i].Score)
		}
	}

	extraWithLrclib := append(extra, scoredLyricCandidateResult{Source: "lrclib", Lyrics: timed, Score: 200, Title: "extra-lrclib"})
	merged2 := mergeLyricCandidateRounds("someone & 别人", "song", "album", 0, base, extraWithLrclib)
	for _, r := range merged2 {
		if r.Instrumental {
			t.Errorf("instrumental marker kept although a real lrclib candidate exists")
		}
	}
}

func TestNeedsRomanizationRetry(t *testing.T) {
	cases := []struct {
		name    string
		results []scoredLyricCandidateResult
		want    bool
	}{
		{"没有候选", nil, false},
		{
			"纯英文歌_不需要",
			[]scoredLyricCandidateResult{
				{Source: "musixmatch", Lyrics: "Oh Erica, baby Erica"},
				{Source: "lrclib", Lyrics: "Oh Erica, baby Erica"},
			},
			false,
		},
		{

			"汉字歌词_没有语种信号_需要重试",
			[]scoredLyricCandidateResult{
				{Source: "musixmatch", Lyrics: "知你其實想找一個水泡救生嗎"},
				{Source: "lrclib", Lyrics: "知你其實想找一個水泡救生嗎"},
			},
			true,
		},
		{
			"汉字歌词_但已有语种信号_不需要",
			[]scoredLyricCandidateResult{
				{Source: "musixmatch", Lyrics: "知你其實想找一個水泡救生嗎"},
				{Source: "qq", Lyrics: "知你其實想找一個水泡救生嗎", Language: "yue"},
			},
			false,
		},
		{
			"汉字歌词_但已有罗马音_不需要",
			[]scoredLyricCandidateResult{
				{Source: "netease", Lyrics: "知你其實想找一個水泡救生嗎", LyricsRoma: "zi1 nei5 kei4 sat6..."},
			},
			false,
		},
		{
			"日语假名为主_需要重试",
			[]scoredLyricCandidateResult{
				{Source: "musixmatch", Lyrics: "きっと忘れられない くらい素敵な日々を"},
			},
			true,
		},
		{
			"韩语谚文_需要重试",
			[]scoredLyricCandidateResult{
				{Source: "musixmatch", Lyrics: "사랑해 진짜 진짜 많이 사랑해"},
			},
			true,
		},
		{
			"候选有歌词字段为空_不参与文字系统判断",
			[]scoredLyricCandidateResult{
				{Source: "qq", Lyrics: "", Score: -1},
				{Source: "kugou", Lyrics: "", Score: -1},
			},
			false,
		},
	}
	for _, c := range cases {
		if got := needsRomanizationRetry(c.results); got != c.want {
			t.Errorf("%s: needsRomanizationRetry = %v, want %v", c.name, got, c.want)
		}
	}
}
