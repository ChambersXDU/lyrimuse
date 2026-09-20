package main

import "testing"

func TestDigestLastfmPathMergesArtists(t *testing.T) {

	in := []lastfmChartEntry{
		{Name: "周杰伦", PlayCount: 5},
		{Name: "张震岳", PlayCount: 4},
		{Name: "张震嶽", PlayCount: 3},
	}
	got := digestTopArtists(in)

	if len(got) != 2 {
		t.Fatalf("繁简孪生没有被合并: got %d entries %+v", len(got), got)
	}

	if got[0].Count != 7 {
		t.Fatalf("合并后应按次数降序重排(张震岳 4+3=7 居首), got %+v", got)
	}
	if got[1].Name != "周杰伦" || got[1].Count != 5 {
		t.Fatalf("无关歌手被改动了: %+v", got)
	}
}

func TestDigestTopArtistsMergesBeforeTruncating(t *testing.T) {
	in := []lastfmChartEntry{
		{Name: "A", PlayCount: 9},
		{Name: "B", PlayCount: 8},
		{Name: "C", PlayCount: 7},
		{Name: "张震岳", PlayCount: 6},
		{Name: "张震嶽", PlayCount: 6},
	}
	got := digestTopArtists(in)
	if len(got) != digestTopN {
		t.Fatalf("应恰好取 %d 条, got %d", digestTopN, len(got))
	}

	if got[0].Count != 12 {
		t.Fatalf("归并必须发生在截断之前, got %+v", got)
	}
}

func TestDigestListenBrainzPathMergesArtists(t *testing.T) {

	same := []string{"张震岳", "张震嶽"}
	k0 := artistMergeNameKey(same[0])
	for _, s := range same[1:] {
		if k := artistMergeNameKey(s); k != k0 {
			t.Fatalf("%q 与 %q 应折成同一个键, got %q vs %q", same[0], s, k0, k)
		}
	}
	if artistMergeNameKey("周杰伦") == k0 {
		t.Fatal("不相干的歌手不该折成同一个键")
	}

	if got := artistMergeDisplayName("张震嶽"); got != "张震嶽" {
		t.Fatalf("展示名不该被折成简体, got %q", got)
	}
}
