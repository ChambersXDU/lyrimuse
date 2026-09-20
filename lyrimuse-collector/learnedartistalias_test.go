package main

import "testing"

func learnedEntry(winner, sourceArtist string, losers ...string) enrichEntry {
	cands := []lyricsDecisionCandidate{{Source: winner, Artist: sourceArtist}}
	for i, l := range losers {
		cands = append(cands, lyricsDecisionCandidate{Source: "loser" + string(rune('a'+i)), Artist: l})
	}
	return enrichEntry{
		Lyrics:                "[00:01.00]x",
		LyricsDecisionApplied: &lyricsDecision{Winner: winner, Candidates: cands},
	}
}

func TestLearnedSourceArtistAliasLearnsFromSiblingTracks(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|The Guilty Ones|":                learnedEntry("kugou", "Prince"),
		"王子|Why You Wanna Treat Me So Bad?|": learnedEntry("kugou", "Prince"),

		"周杰伦|七里香|": learnedEntry("netease", "Jay Chou"),
	})
	if got := learnedSourceArtistAlias("王子"); got != "Prince" {
		t.Fatalf("learnedSourceArtistAlias(王子) = %q, want Prince", got)
	}
}

func TestLearnedSourceArtistAliasRefusesWhenAmbiguous(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|The Guilty Ones|": learnedEntry("kugou", "Prince"),
		"王子|夢見|":              learnedEntry("qq", "邱勝翊"),
	})
	if got := learnedSourceArtistAlias("王子"); got != "" {
		t.Fatalf("歧义时应当放弃,却学到了 %q", got)
	}
}

func TestLearnedSourceArtistAliasIsDeterministic(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|a|": learnedEntry("kugou", "Prince"),
		"王子|b|": learnedEntry("qq", "PRINCE"),
		"王子|c|": learnedEntry("netease", "prince"),
	})
	first := learnedSourceArtistAlias("王子")
	if first != "PRINCE" {
		t.Fatalf("应当返回字典序最小的写法 PRINCE,得到 %q", first)
	}
	for i := 0; i < 30; i++ {
		if got := learnedSourceArtistAlias("王子"); got != first {
			t.Fatalf("第 %d 次得到 %q,与首次 %q 不一致 —— 没有定序", i, got, first)
		}
	}
}

func TestLearnedSourceArtistAliasIgnoresUnresolvedEntries(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|1999 (Edit)|": {TS: 1788890000},
		"王子|别的歌|":         {LyricsDecisionApplied: &lyricsDecision{Winner: ""}},
	})
	if got := learnedSourceArtistAlias("王子"); got != "" {
		t.Fatalf("没有成功条目时不该学到东西,得到 %q", got)
	}
}

func TestLearnedSourceArtistAliasIgnoresLosingCandidates(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|The Guilty Ones|": learnedEntry("kugou", "Prince", "冒牌王子", "Another Prince"),
	})
	if got := learnedSourceArtistAlias("王子"); got != "Prince" {
		t.Fatalf("只该认胜出候选的署名,得到 %q", got)
	}
}

func TestLearnedSourceArtistAliasSkipsSelf(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"周杰伦|七里香|": learnedEntry("netease", "周杰伦"),
	})
	if got := learnedSourceArtistAlias("周杰伦"); got != "" {
		t.Fatalf("跟本地标签相同不算别名,得到 %q", got)
	}
}

func TestLearnedSourceArtistAliasMatchesArtistSegmentExactly(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"小王子|某首歌|": learnedEntry("kugou", "Le Petit Prince"),
		"王子李|某首歌|": learnedEntry("qq", "Wang Zili"),
	})
	if got := learnedSourceArtistAlias("王子"); got != "" {
		t.Fatalf("不该匹配到别的歌手,得到 %q", got)
	}
}

func TestLearnedSourceArtistAliasEmptyArtist(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"|某首歌|": learnedEntry("kugou", "Whoever"),
	})
	if got := learnedSourceArtistAlias(""); got != "" {
		t.Fatalf("空歌手名应当直接返回空,得到 %q", got)
	}
}

func TestLyricsRoundConfirmsNoResult(t *testing.T) {
	cases := []struct {
		name               string
		attempts, failures int32
		want               bool
	}{
		{"九源都问过、大多成功、就是没有这首歌", 24, 3, true},
		{"全部成功但一条候选都没有", 18, 0, true},
		{"整轮零请求(全命中缓存)不构成证据", 0, 0, false},
		{"只发了一个请求还挂了 —— 更像没查成", 1, 1, false},
		{"两个请求全挂,roundLooksNetworkDown 抓不到,这里要抓住", 2, 2, false},
		{"三个全挂(网络不通那一档)", 3, 3, false},
		{"发得多、挂得多,但有成功的 → 仍算问过了", 20, 19, true},
	}
	for _, c := range cases {
		if got := lyricsRoundConfirmsNoResult(c.attempts, c.failures); got != c.want {
			t.Errorf("%s: attempts=%d failures=%d → %v, want %v", c.name, c.attempts, c.failures, got, c.want)
		}
	}
}

func TestLyricsRoundConfirmsNoResultNeverOverlapsNetworkDown(t *testing.T) {
	for attempts := int32(0); attempts <= 30; attempts++ {
		for failures := int32(0); failures <= attempts; failures++ {
			if roundLooksNetworkDown(attempts, failures) && lyricsRoundConfirmsNoResult(attempts, failures) {
				t.Fatalf("attempts=%d failures=%d 同时被判成网络不通和确证查无", attempts, failures)
			}
		}
	}
}
