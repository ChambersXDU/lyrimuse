package main

import (
	"context"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLyricSourcesWorthAliasRetry(t *testing.T) {
	savedSources := getFeaturesLyricsSources()
	savedBreaker := lyricSourceBreakerShared
	savedYT, savedMM := ytmusicLastFailureReasonNow(), musixmatchLastFailureReasonNow()
	savedDZ := deezerLastFailureReasonNow()
	t.Cleanup(func() {
		setFeaturesLyricsSources(savedSources)
		lyricSourceBreakerShared = savedBreaker
		ytmusicSetLastFailureReason(savedYT)
		musixmatchSetLastFailureReason(savedMM)
		deezerSetLastFailureReason(savedDZ)
	})
	sources := map[string]bool{}
	for _, s := range lyricSourceNames {
		sources[s] = true
	}
	sources["migu"] = false
	setFeaturesLyricsSources(sources)
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)

	dns := &url.Error{Op: "Get", Err: &net.OpError{Op: "dial", Err: &net.DNSError{Err: "no such host", IsNotFound: true}}}
	lyricSourceBreakerShared.observe("search.kuwo.cn", dns, 0, "")

	ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
	musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchDirectBlocked)
	deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)

	results := []scoredLyricCandidateResult{
		{Source: "netease", Score: 579},
		{Source: "lrclib", Score: -1},
		{Source: "qq", Score: -1, Instrumental: true},
	}
	got := lyricSourcesWorthAliasRetry(results)
	want := []string{"qq", "kugou", "lrclib", "amll"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v want %v", got, want)
	}

	full := []scoredLyricCandidateResult{}
	for _, s := range lyricSourceNames {
		full = append(full, scoredLyricCandidateResult{Source: s, Score: 100})
	}
	if got := lyricSourcesWorthAliasRetry(full); len(got) != 0 {
		t.Fatalf("全部可用时应为空,得到 %v", got)
	}

	ytmusicSetLastFailureReason("")
	musixmatchSetLastFailureReason("")
	deezerSetLastFailureReason("")
	got = lyricSourcesWorthAliasRetry(results)
	if !containsString(got, "lyricfind") || !containsString(got, "musixmatch") || !containsString(got, "deezer") {
		t.Fatalf("没有具体失败原因时 lyricfind / musixmatch / deezer 应算缺,得到 %v", got)
	}
}

func TestWithLyricSourceOnly(t *testing.T) {
	base := context.Background()
	if lyricSourceOnlyFrom(base) != nil {
		t.Fatal("没挂名单应返回 nil")
	}
	if withLyricSourceOnly(base, nil) != base || withLyricSourceOnly(base, []string{}) != base {
		t.Fatal("空名单应原样返回 ctx(不限制)")
	}
	ctx := withLyricSourceOnly(base, []string{"qq", "musixmatch"})
	set := lyricSourceOnlyFrom(ctx)
	if !set["qq"] || !set["musixmatch"] || set["netease"] || len(set) != 2 {
		t.Fatalf("名单不对:%v", set)
	}
	if lyricSourceOnlyFrom(nil) != nil {
		t.Fatal("nil ctx 应返回 nil")
	}

	ctx2, round := withLyricSourceRound(ctx)
	if lyricSourceOnlyFrom(ctx2)["qq"] != true || lyricSourceRoundFrom(ctx2) != round {
		t.Fatal("两个 ctx 值应共存")
	}
}

func TestAliasRoundTargetingIsWired(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	for _, needle := range []string{
		"only := lyricSourceOnlyFrom(ctx)",
		"if only != nil && !only[source] {",

		"withLyricSourceOnly(ctx, only)",
		"fetchScoredLyricCandidatesStreaming(altCtx, alt, title, album, durationSecs, aliasUpdate)",
		"missing := lyricSourcesWorthAliasRetry(results)",

		"aliasReason := lyricQueryReasonAliasMissing",
		"altCtx := withLyricQueryReason(withLyricSourceOnly(ctx, only), aliasReason)",
	} {
		if !strings.Contains(s, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}

	if strings.Contains(s, "if !hasUsableLyricCandidate(results) || needsRomanizationRetry(results) {") {
		t.Error("别名轮又退回'一个能用的都没有才跑'的老条件")
	}
}
