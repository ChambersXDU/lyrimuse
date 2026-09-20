package main

import "testing"

func uchiagehanabiSearchResults() []albumTrack {
	tracks := []albumTrack{
		{title: "打上花火", artist: "米津玄師", duration: 259.459},
		{title: "Lemon", artist: "米津玄師", duration: 256.000},
		{title: "IRIS OUT", artist: "米津玄師", duration: 151.626},
		{title: "LOSER", artist: "米津玄師", duration: 243.879},
		{title: "KICK BACK", artist: "米津玄師", duration: 193.561},
		{title: "BOW AND ARROW", artist: "米津玄師", duration: 175.775},
		{title: "烏 - Raven", artist: "米津玄師", duration: 248.528},
		{title: "M八七", artist: "米津玄師", duration: 263.123},
		{title: "地球儀", artist: "米津玄師", duration: 273.437},
		{title: "さよーならまたいつか！", artist: "米津玄師", duration: 201.280},
		{title: "PLACEBO", artist: "米津玄師", duration: 218.000},
		{title: "春雷", artist: "米津玄師", duration: 288.949},
	}
	for len(tracks) < 23 {
		tracks = append(tracks, albumTrack{
			title: "填充" + string(rune('A'+len(tracks))), artist: "米津玄師", duration: 200.0})
	}
	return append(tracks,
		albumTrack{title: "打上花火 (Cover)", artist: "米津玄師", duration: 288.376},
		albumTrack{title: "打上花火 (Cover) [其他]", artist: "米津玄師", duration: 288.376},
		albumTrack{title: "填充X", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充Y", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充Z", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充W", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "Uchiage Hanabi", artist: "米津玄師", duration: 287.432},
	)
}

func loveLoveLoveSearchResults() []albumTrack {
	tracks := []albumTrack{
		{title: "特别的人", artist: "方大同", duration: 259.064},
		{title: "爱爱爱", artist: "方大同", duration: 213.266},
		{title: "Love Song", artist: "方大同", duration: 269.293},
		{title: "天气先生", artist: "方大同", duration: 271.583},
		{title: "Love Song [Timeless Live]", artist: "方大同", duration: 270.133},
	}
	for len(tracks) < 12 {
		tracks = append(tracks, albumTrack{
			title: "填充" + string(rune('A'+len(tracks))), artist: "方大同", duration: 240.0})
	}

	tracks = append(tracks, albumTrack{title: "爱爱爱", artist: "方大同", duration: 213.266})
	for len(tracks) < 18 {
		tracks = append(tracks, albumTrack{
			title: "填充b" + string(rune('A'+len(tracks))), artist: "方大同", duration: 240.0})
	}

	return append(tracks, albumTrack{title: "听", artist: "方大同", duration: 212.304})
}

func TestArtistSearchRankCutoffRejectsCatalogCollision(t *testing.T) {
	const localDuration = 289.334
	all := uchiagehanabiSearchResults()

	if got, _, ok := bestAlbumTrackByDurationDetailed(all, localDuration); !ok || got != "春雷" {
		t.Fatalf("前置条件不成立:不截断时应当仍然选出《春雷》,实际 got=%q ok=%v", got, ok)
	}

	if got, _, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(all, retryTitleFromArtistSearchMaxRank), localDuration); ok {
		t.Fatalf("名次截断后应当弃权,实际选出了 %q", got)
	}
}

func TestArtistSearchRankCutoffKeepsKnownGoodCases(t *testing.T) {

	got, diff, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(loveLoveLoveSearchResults(), retryTitleFromArtistSearchMaxRank), 213.0)
	if !ok || got != "爱爱爱" {
		t.Fatalf("爱爱爱案被打死了:got=%q ok=%v", got, ok)
	}
	if diff > 0.3 {
		t.Fatalf("爱爱爱案的时长误差不该这么大:%v", diff)
	}

	airport := []albumTrack{
		{title: "飞机场的10:30", artist: "陶喆", duration: 280.773},
		{title: "飞机场的10:30 (Live)", artist: "陶喆", duration: 336.245},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(airport, retryTitleFromArtistSearchMaxRank), 280.773); !ok || got != "飞机场的10:30" {
		t.Fatalf("飞机场案被打死了:got=%q ok=%v", got, ok)
	}
}

func TestTopSearchRanked(t *testing.T) {
	five := []albumTrack{{title: "a"}, {title: "b"}, {title: "c"}, {title: "d"}, {title: "e"}}
	if got := topSearchRanked(five, 3); len(got) != 3 || got[2].title != "c" {
		t.Fatalf("截断应当保序取前 3 条,实际 %v", got)
	}

	if got := topSearchRanked(five, 99); len(got) != 5 {
		t.Fatalf("不足 n 条应当全给,实际 %d 条", len(got))
	}
	if got := topSearchRanked(five, 0); len(got) != 5 {
		t.Fatalf("n<=0 应当原样返回,实际 %d 条", len(got))
	}
	if got := topSearchRanked(nil, 5); got != nil {
		t.Fatalf("空表应当原样返回,实际 %v", got)
	}
}

func TestAmbiguityGuardUsesRealMargin(t *testing.T) {
	const local = 200.0

	close2 := []albumTrack{
		{title: "甲", artist: "X", duration: 200.1},
		{title: "乙", artist: "X", duration: 200.4},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(close2, local); ok {
		t.Fatalf("两首异名歌相差 0.3s 时应当弃权,实际选出 %q", got)
	}

	if got, _, ok := bestAlbumTrackByDurationDetailed(
		[]albumTrack{close2[1], close2[0]}, local); ok {
		t.Fatalf("换个顺序也应当弃权,实际选出 %q", got)
	}

	far := []albumTrack{
		{title: "甲", artist: "X", duration: 200.1},
		{title: "乙", artist: "X", duration: 201.3},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(far, local); !ok || got != "甲" {
		t.Fatalf("差 1.2s 不该算歧义:got=%q ok=%v", got, ok)
	}

	dupes := []albumTrack{
		{title: "爱爱爱", artist: "方大同", duration: 213.266},
		{title: "爱爱爱", artist: "方大同", duration: 213.266},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(dupes, 213.0); !ok || got != "爱爱爱" {
		t.Fatalf("同名重复收录不该算歧义:got=%q ok=%v", got, ok)
	}
}
