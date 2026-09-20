package main

import "testing"

func TestPickLyricCandidateModes(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 300},
		{Source: "qq", Score: 900},
		{Source: "kugou", Score: 500},
	}
	enabled := map[string]bool{"netease": true, "qq": true, "kugou": true, "lrclib": true}

	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "qq" {
		t.Fatalf("智能模式该取最高分 qq(900),得到 %v", got)
	}

	features = featureFlags{
		LyricsSources:     enabled,
		LyricsSourceMode:  lyricsModePriority,
		LyricsSourceOrder: []string{"kugou", "qq", "netease"},
	}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("顺序优先该取配置里第一个能用的 kugou,得到 %v", got)
	}

	withRejected := []scoredLyricCandidateResult{
		{Source: "kugou", Score: -1},
		{Source: "qq", Score: 900},
	}
	if got := pickLyricCandidate(withRejected); got == nil || got.Source != "qq" {
		t.Fatalf("顺序优先要跳过 Score<0 的候选,得到 %v", got)
	}

	features = featureFlags{
		LyricsSources:    map[string]bool{"netease": true, "kugou": true},
		LyricsSourceMode: lyricsModeSmart,
	}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("关掉 qq 之后该取 kugou(500),得到 %v", got)
	}

	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}
	allRejected := []scoredLyricCandidateResult{
		{Source: "qq", Score: -1},
		{Source: "kugou", Score: -1},
	}
	if got := pickLyricCandidate(allRejected); got != nil {
		t.Fatalf("全部判废时该返回 nil,得到 %v", got)
	}

	tie := []scoredLyricCandidateResult{
		{Source: "netease", Score: 700},
		{Source: "qq", Score: 700},
	}
	first := pickLyricCandidate(tie)
	second := pickLyricCandidate(tie)
	if first == nil || second == nil || first.Source != second.Source || first.Source != "netease" {
		t.Fatalf("同分该稳定取先到的 netease,得到 %v / %v", first, second)
	}
}

func TestPickLyricCandidatePreferring(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 300},
		{Source: "qq", Score: 900},
		{Source: "kugou", Score: 500},
	}
	enabled := map[string]bool{"netease": true, "qq": true, "kugou": true, "lrclib": true}
	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}

	if got := pickLyricCandidatePreferring(scored, ""); got == nil || got.Source != "qq" {
		t.Fatalf("空 choice 该退化成普通挑选(qq 900),得到 %v", got)
	}

	if got := pickLyricCandidatePreferring(scored, "kugou"); got == nil || got.Source != "kugou" {
		t.Fatalf("选定 kugou 时该取 kugou(500)而不是最高分,得到 %v", got)
	}

	sameSource := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 400},
		{Source: "kugou", Score: 800},
		{Source: "qq", Score: 999},
	}
	if got := pickLyricCandidatePreferring(sameSource, "kugou"); got == nil || got.Score != 800 {
		t.Fatalf("同源内该取最好的那条(800),得到 %v", got)
	}

	if got := pickLyricCandidatePreferring(scored, "musixmatch"); got != nil {
		t.Fatalf("选定的源没有候选时该返回 nil(不换),得到 %v", got)
	}

	rejected := []scoredLyricCandidateResult{
		{Source: "kugou", Score: -1},
		{Source: "qq", Score: 900},
	}
	if got := pickLyricCandidatePreferring(rejected, "kugou"); got != nil {
		t.Fatalf("选定的源只有不可用候选时该返回 nil,得到 %v", got)
	}

	features = featureFlags{
		LyricsSources:    map[string]bool{"netease": true, "qq": true, "lrclib": true},
		LyricsSourceMode: lyricsModeSmart,
	}
	if got := pickLyricCandidatePreferring(scored, "kugou"); got != nil {
		t.Fatalf("选定的源被禁用时该返回 nil(不换),得到 %v", got)
	}
}
