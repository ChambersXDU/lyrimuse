package main

import "testing"

func TestPickLRCLIBSearchResult(t *testing.T) {
	lrc := "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n"
	item := func(track string, dur float64, synced string) lrclibSearchItem {
		return lrclibSearchItem{TrackName: track, ArtistName: "Michael Jackson", AlbumName: "XSCAPE", Duration: dur, SyncedLyrics: synced}
	}

	got := pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta", 4, lrc),
		item("Blue Gangsta", 257, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got == nil || got.Duration != 257 {
		t.Errorf("应挑到 257s 那条(而不是 4s 的脏数据),实际 %v", got)
	}

	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta", 270, lrc),
		item("Blue Gangsta", 256, lrc),
		item("Blue Gangsta", 240, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got == nil || got.Duration != 256 {
		t.Errorf("应取最接近 255s 的 256s,实际 %v", got)
	}

	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta (Live)", 255, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got != nil {
		t.Errorf("版本限定词相反的候选不该被采纳,实际 %v", got.TrackName)
	}

	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta (Live)", 255, lrc),
	}, "Michael Jackson", "Blue Gangsta (Live)", "", 255)
	if got == nil {
		t.Error("两边都是 Live 版应该采纳")
	}

	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 255, "")}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("syncedLyrics 为空的候选不该被采纳")
	}
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 255, "no timestamps here")}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("没有时间戳的候选不该被采纳")
	}

	bad := item("Blue Gangsta", 255, lrc)
	bad.ArtistName = "Someone Else"
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{bad}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("歌手对不上的候选不该被采纳")
	}

	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 600, lrc)}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("时长差一倍以上的候选不该被采纳")
	}

	got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 0, lrc), item("Blue Gangsta", 257, lrc)}, "Michael Jackson", "Blue Gangsta", "", 0)
	if got == nil || got.Duration != 0 {
		t.Errorf("本地时长未知时应取第一个过门的候选,实际 %v", got)
	}

	if got = pickLRCLIBSearchResult(nil, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("空候选列表应返回 nil")
	}
}

func TestLRCLIBTitleGate(t *testing.T) {
	cases := []struct {
		candidate, local string
		want             bool
		label            string
	}{
		{"Blue Gangsta", "Blue Gangsta", true, "完全相同"},
		{"blue gangsta", "Blue Gangsta", true, "大小写不敏感"},
		{"Blue  Gangsta", "Blue Gangsta", true, "空白差异归一化后相等"},

		{"Blue Gangsta (Remastered)", "Blue Gangsta", true, "候选带括号后缀,去括号后相等"},
		{"Blue Gangsta", "Blue Gangsta (feat. X)", true, "本地带括号后缀,去括号后相等"},

		{"Real Love", "Love", false, "候选包含本地曲名(另一首歌)→ 拒"},
		{"Real Love Baby", "Real Love", false, "候选更长(另一首歌)→ 拒"},
		{"Love", "Real Love", false, "本地包含候选曲名 → 拒"},
		{"Beat It", "Bad", false, "完全不同 → 拒"},
		{"", "Blue Gangsta", false, "候选空 → 拒"},
		{"Blue Gangsta", "", false, "本地空 → 拒"},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("%s: lyricTitleAccepted(%q, %q) = %v, want %v", c.label, c.candidate, c.local, got, c.want)
		}
	}
}

func TestPickLRCLIBSearchResultRejectsNearMissTitle(t *testing.T) {
	lrc := "[00:01.00]a\n[00:05.00]b\n[00:09.00]c\n"
	items := []lrclibSearchItem{
		{TrackName: "Real Love", ArtistName: "Michael Jackson", Duration: 255, SyncedLyrics: lrc},
	}
	if got := pickLRCLIBSearchResult(items, "Michael Jackson", "Love", "", 255); got != nil {
		t.Errorf("同歌手的近似曲名不该被采纳,实际选中 %q", got.TrackName)
	}
}
