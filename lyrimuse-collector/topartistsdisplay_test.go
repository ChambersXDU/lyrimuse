package main

import "testing"

func TestMergeAliasedArtistsDisplayName(t *testing.T) {
	const kdaCollab = "K/DA/Madison Beer/(G)I-DLE/Jaira Burns"

	withCachedAliases(t, map[string]string{
		"K/DA": "", "Madison Beer": "", "Prince": "", "IU": "", "Sigur Rós": "", "Sigur Ros": "",
	})
	withCachedMBAliases(t, map[string][]string{
		"K/DA": nil, "Madison Beer": nil, "Prince": nil, "IU": nil, "Sigur Rós": nil, "Sigur Ros": nil,
	})
	withCachedQQArtistNames(t, map[string]string{
		"K/DA": "", "Madison Beer": "", "Prince": "", "IU": "", "Sigur Rós": "", "Sigur Ros": "",

		"Dean Ting": "丁世光",
	})

	t.Run("名字自带斜杠的歌手显示本名而不是被切开的前半截", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "K/DA", PlayCount: 30},
			{Name: kdaCollab, PlayCount: 12},
			{Name: "Madison Beer", PlayCount: 20},
		})
		want := []lastfmChartEntry{
			{Name: "K/DA", PlayCount: 42},
			{Name: "Madison Beer", PlayCount: 20},
		}
		assertChart(t, got, want)
	})

	t.Run("本名条目排在合credit 串后面也要胜出", func(t *testing.T) {

		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: kdaCollab, PlayCount: 40},
			{Name: "K/DA", PlayCount: 3},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "K/DA", PlayCount: 43}})
	})

	t.Run("合credit 串单独出现时原样显示,不猜第一个歌手", func(t *testing.T) {

		got := mergeAliasedArtists([]lastfmChartEntry{{Name: kdaCollab, PlayCount: 7}})
		assertChart(t, got, []lastfmChartEntry{{Name: kdaCollab, PlayCount: 7}})
	})

	t.Run("经典合唱串跟本名同时在榜时显示本名", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Prince & The Revolution", PlayCount: 25},
			{Name: "Prince", PlayCount: 9},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "Prince", PlayCount: 34}})
	})

	t.Run("已知别名仍然换成中文名", func(t *testing.T) {

		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Dean Ting", PlayCount: 11},
			{Name: "丁世光", PlayCount: 4},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "丁世光", PlayCount: 15}})
	})

	t.Run("mbid 相同照旧合并", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Sigur Rós", PlayCount: 8, Mbid: "abc"},
			{Name: "Sigur Ros", PlayCount: 5, Mbid: "abc"},
		})
		assertChart(t, got, []lastfmChartEntry{{Name: "Sigur Rós", PlayCount: 13}})
	})

	t.Run("毫无关系的歌手不合并", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "IU", PlayCount: 9},
			{Name: "K/DA", PlayCount: 6},
		})
		assertChart(t, got, []lastfmChartEntry{
			{Name: "IU", PlayCount: 9},
			{Name: "K/DA", PlayCount: 6},
		})
	})
}

func assertChart(t *testing.T, got, want []lastfmChartEntry) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("条目数 = %d, want %d；实际 = %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i].Name != want[i].Name || got[i].PlayCount != want[i].PlayCount {
			t.Errorf("第 %d 条 = {%q, %d}, want {%q, %d}",
				i, got[i].Name, got[i].PlayCount, want[i].Name, want[i].PlayCount)
		}
	}
}
