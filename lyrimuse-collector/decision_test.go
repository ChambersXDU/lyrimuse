package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestBuildLyricsDecisionOmitsLyricsText(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: "SECRET_LYRICS_BODY", Score: 525,
			ScoreTerms: []scoreTerm{{Kind: scoreTermDuration, Points: 300}},
			Title:      "悟空", Artist: "戴荃", Album: "悟空"},
		{Source: "lrclib", Lyrics: "ANOTHER_BODY", Score: 83},
	}
	d := buildLyricsDecision("first-resolve", "戴荃", "悟空", "悟空", 289.5, scored, &scored[0], true)
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(blob), "SECRET_LYRICS_BODY") || strings.Contains(string(blob), "ANOTHER_BODY") {
		t.Fatalf("决策记录里带上了歌词正文 —— 缓存文件会因此翻倍: %s", blob)
	}
	if d.Winner != "netease" || !d.Applied {
		t.Fatalf("winner/applied 不对: %+v", d)
	}
	if len(d.Candidates) != 2 || d.Candidates[0].Score != 525 {
		t.Fatalf("候选表不完整: %+v", d.Candidates)
	}
}

func TestBuildLyricsDecisionKeepsRejectedCandidates(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "qq", Score: 482, Title: "某歌"},
		{Source: "kugou", Score: -1,
			ScoreTerms: []scoreTerm{{Kind: "rejectNotTimed", Points: 0}}},
	}
	d := buildLyricsDecision("upgrade", "a", "t", "", 200, scored, &scored[0], false)
	if len(d.SourcesResponded) != 2 {
		t.Fatalf("负分候选的源没算进应答清单: %v", d.SourcesResponded)
	}
	if len(d.Candidates) != 2 || d.Candidates[1].Score != -1 ||
		len(d.Candidates[1].ScoreTerms) != 1 {
		t.Fatalf("被拒候选(及其原因)没保留: %+v", d.Candidates)
	}
	if d.Applied {
		t.Fatal("这一轮明明维持现状,Applied 却是 true —— 记录语义见 decision.go")
	}
	if d.Winner != "qq" {
		t.Fatalf("winner = %q", d.Winner)
	}
}

func TestBuildLyricsDecisionNoWinner(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: -1, Instrumental: true},
	}
	d := buildLyricsDecision("first-resolve", "a", "t", "", 0, scored, nil, false)
	if d.Winner != "" || d.Applied {
		t.Fatalf("无胜者时 winner/applied 应为空/false: %+v", d)
	}
	if len(d.Candidates) != 1 || !d.Candidates[0].Instrumental {
		t.Fatalf("纯音乐标记没保留: %+v", d.Candidates)
	}
}
