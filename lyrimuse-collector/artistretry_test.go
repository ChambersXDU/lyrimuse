package main

import (
	"context"
	"testing"
)

func withCachedAliases(t *testing.T, entries map[string]string) {
	t.Helper()
	artistAliasMu.Lock()
	saved := make(map[string]string, len(artistAliasCache))
	for k, v := range artistAliasCache {
		saved[k] = v
	}
	savedDirty := artistAliasDirty
	for k, v := range entries {
		artistAliasCache[k] = v
	}
	artistAliasMu.Unlock()

	t.Cleanup(func() {
		artistAliasMu.Lock()
		artistAliasCache = saved
		artistAliasDirty = savedDirty
		artistAliasMu.Unlock()
	})
}

func withCachedMBAliases(t *testing.T, entries map[string][]string) {
	t.Helper()
	mbPrimaryNameMu.Lock()
	saved := make(map[string][]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		saved[k] = v
	}
	savedDirty := mbPrimaryNameDirty
	for k, v := range entries {
		mbPrimaryNameCache[k] = v
	}
	mbPrimaryNameMu.Unlock()

	t.Cleanup(func() {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = saved
		mbPrimaryNameDirty = savedDirty
		mbPrimaryNameMu.Unlock()
	})
}

func withEnrichCache(t *testing.T, m map[string]enrichEntry) {
	t.Helper()
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	if m == nil {
		m = map[string]enrichEntry{}
	}
	enrichCache = m
}

func TestRetryArtistIdentitiesUsesMusicBrainzName(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedAliases(t, map[string]string{"Faye Wong": "王菲"})
	withCachedMBAliases(t, map[string][]string{"Faye Wong": nil})
	withCachedQQArtistNames(t, map[string]string{"Faye Wong": ""})

	got := retryArtistIdentities(context.Background(), "Faye Wong")
	if len(got) != 1 || got[0] != "王菲" {
		t.Fatalf("MusicBrainz 查到的名字要能当检索词, got %v", got)
	}
}

func TestRetryArtistIdentitiesDedupes(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedAliases(t, map[string]string{"david tao": "陶喆"})
	withCachedMBAliases(t, map[string][]string{"david tao": {"陶喆"}})
	withCachedQQArtistNames(t, map[string]string{"david tao": "陶喆"})

	got := retryArtistIdentities(context.Background(), "david tao")
	if len(got) != 1 || got[0] != "陶喆" {
		t.Fatalf("同一个名字不该搜两遍, got %v", got)
	}
}

func TestRetryArtistIdentitiesDoesNotFallBackToHandTable(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedAliases(t, map[string]string{"david tao": ""})
	withCachedMBAliases(t, map[string][]string{"david tao": nil})
	withCachedQQArtistNames(t, map[string]string{"david tao": ""})

	if got := retryArtistIdentities(context.Background(), "david tao"); len(got) != 0 {
		t.Fatalf("手工表已经从这条路径退休,不该再出现在结果里, got %v", got)
	}
}

func TestRetryArtistIdentitiesSkipsOriginalName(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedAliases(t, map[string]string{"Prince": "  prince  "})
	withCachedMBAliases(t, map[string][]string{"Prince": nil})
	withCachedQQArtistNames(t, map[string]string{"Prince": ""})

	if got := retryArtistIdentities(context.Background(), "Prince"); len(got) != 0 {
		t.Fatalf("跟原名等价的不该进重试列表, got %v", got)
	}
}

func TestRetryArtistIdentitiesEmptyForUnknownChineseArtist(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedMBAliases(t, map[string][]string{"某个没登记过的歌手": nil})
	if got := retryArtistIdentities(context.Background(), "某个没登记过的歌手"); len(got) != 0 {
		t.Fatalf("没有任何备选身份时应为空, got %v", got)
	}
}

func TestRetryArtistIdentitiesFallsBackToQQ(t *testing.T) {
	withEnrichCache(t, nil)
	withCachedAliases(t, map[string]string{"Na Ying": ""})
	withCachedMBAliases(t, map[string][]string{"Na Ying": nil})
	withCachedQQArtistNames(t, map[string]string{"Na Ying": "那英"})

	got := retryArtistIdentities(context.Background(), "Na Ying")
	if len(got) != 1 || got[0] != "那英" {
		t.Fatalf("MusicBrainz 都查空时应该用 QQ 查到的名字, got %v", got)
	}
}

func TestRetryArtistIdentitiesGenericMusicBrainzReverseDirection(t *testing.T) {
	withEnrichCache(t, nil)
	const artist = "方大同"

	aliases, err := lookupMusicBrainzArtistAliases(context.Background(), artist)
	if err != nil {
		t.Skipf("MusicBrainz 这一刻没给出可用响应(%v),跳过 —— 这条测试按设计打真实网络,"+
			"对方过载/限速时它的红不代表本仓库有回归;要复现请稍后重跑", err)
	}

	withCachedMBAliases(t, map[string][]string{artist: aliases})
	withCachedQQArtistNames(t, map[string]string{artist: ""})

	for _, s := range retryArtistIdentities(context.Background(), artist) {
		if normLoose(s) == normLoose("Khalil Fong") {
			return
		}
	}
	t.Fatalf("通用 MusicBrainz 查询应该能换回国际艺名,不需要手工登记(MB 这一刻答了 %v,"+
		"里面没有 Khalil Fong)", aliases)
}

func withCachedQQArtistNames(t *testing.T, entries map[string]string) {
	t.Helper()
	qqArtistNameMu.Lock()
	saved := make(map[string]string, len(qqArtistNameCache))
	for k, v := range qqArtistNameCache {
		saved[k] = v
	}
	savedDirty := qqArtistNameDirty
	for k, v := range entries {
		qqArtistNameCache[k] = v
	}
	qqArtistNameMu.Unlock()

	t.Cleanup(func() {
		qqArtistNameMu.Lock()
		qqArtistNameCache = saved
		qqArtistNameDirty = savedDirty
		qqArtistNameMu.Unlock()
	})
}

func TestHasUsableLyricCandidate(t *testing.T) {
	cases := []struct {
		name string
		in   []scoredLyricCandidateResult
		want bool
	}{
		{"空列表", nil, false},
		{"全被判废", []scoredLyricCandidateResult{{Score: -1}, {Score: -1}}, false},
		{"有一条能用", []scoredLyricCandidateResult{{Score: -1}, {Score: 120}}, true},
		{"零分也算能用", []scoredLyricCandidateResult{{Score: 0}}, true},
	}
	for _, c := range cases {
		if got := hasUsableLyricCandidate(c.in); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestRetryArtistIdentitiesLearnsFromLocalCache(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"王子|The Guilty Ones|": learnedEntry("kugou", "Prince"),
	})
	withCachedAliases(t, map[string]string{"王子": ""})
	withCachedMBAliases(t, map[string][]string{"王子": nil})
	withCachedQQArtistNames(t, map[string]string{"王子": ""})

	got := retryArtistIdentities(context.Background(), "王子")
	if len(got) != 1 || got[0] != "Prince" {
		t.Fatalf(`retryArtistIdentities("王子") = %v, want ["Prince"]`, got)
	}
}
