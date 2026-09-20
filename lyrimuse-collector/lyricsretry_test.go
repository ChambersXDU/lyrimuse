package main

import (
	"testing"
	"time"
)

func TestNeedsLyricsRetry(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "qq": true, "lrclib": true})

	long, recent := time.Now().Unix()-int64(lyricsRetryInterval/time.Second)-1, time.Now().Unix()

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{
			name: "有源缺席且已过节流窗口:该重试",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: true,
		},
		{
			name: "所有启用的源都露过面:货真价实赢的,不折腾",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"netease", "qq", "lrclib"}, TS: long},
			want: false,
		},
		{
			name: "已经有逐字歌词:最值钱的东西已到手,没什么可升级的",
			e:    enrichEntry{Lyrics: "x", LyricsYRC: "y", LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: false,
		},
		{
			name: "还没到节流窗口:同一首歌反复播放时不能每次都重搜",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: recent},
			want: false,
		},
		{
			name: "重试次数用尽:缺席的源可能真的没这首歌,必须有硬上限",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long, LyricsRetryCount: lyricsRetryMaxAttempts},
			want: false,
		},
		{
			name: "压根没有歌词:交给首次解析那条路,不走这里",
			e:    enrichEntry{LyricsSourcesSeen: []string{"lrclib"}, TS: long},
			want: false,
		},
		{
			name: "老条目(没有 LyricsSourcesSeen):当初正是在没有这层保护时定的,给一次机会",
			e:    enrichEntry{Lyrics: "x", TS: long},
			want: true,
		},
		{
			name: "节流基准取 TS 和 LyricsRetryTS 里更晚的那个:刚重试过就不该又符合条件",
			e:    enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long, LyricsRetryTS: recent},
			want: false,
		},
	}
	for _, c := range cases {
		if got := needsLyricsRetry(c.e, false, false, true); got != c.want {
			t.Errorf("%s: needsLyricsRetry = %v, want %v", c.name, got, c.want)
		}
	}

}

func TestNeedsLyricsRetryIgnoresDisabledSources(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"lrclib": true, "netease": false})
	long := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1

	e := enrichEntry{Lyrics: "x", LyricsSourcesSeen: []string{"lrclib"}, TS: long}
	if needsLyricsRetry(e, false, false, true) {
		t.Error("只有被禁用的 netease 缺席,不该触发重试")
	}
}

func TestLyricSourcesWithCandidates(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: 83},
		{Source: "netease", Score: 525},
		{Source: "lrclib", Score: 12},
		{Source: "musixmatch", Score: -1, Instrumental: true},
	}
	got := lyricSourcesWithCandidates(scored)
	want := []string{"lrclib", "netease"}
	if len(got) != len(want) {
		t.Fatalf("lyricSourcesWithCandidates = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("lyricSourcesWithCandidates = %v, want %v", got, want)
		}
	}
}
