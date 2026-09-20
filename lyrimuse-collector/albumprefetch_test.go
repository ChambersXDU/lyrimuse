package main

import "testing"

func TestAlbumPrefetchGate(t *testing.T) {
	const gate = 100

	pass := []struct {
		candidate, local, why string
	}{
		{"神经志", "神經志 The Journal", "繁简 + 英文副标题(用户实测被 200 挡住的那张)"},
		{"黑色柳丁", "黑色柳丁", "完全相同"},
		{"Bad", "Bad", "完全相同"},
	}
	for _, c := range pass {
		if got := albumScore(c.candidate, c.local); got < gate {
			t.Errorf("应放行(%s): albumScore(%q, %q) = %d, 需要 >= %d",
				c.why, c.candidate, c.local, got, gate)
		}
	}

	reject := []struct{ candidate, local string }{
		{"King of Pop [Box set]", "Bad"},
		{"The Collection", "Bad"},
		{"Ultrasound 乐之路 1997-2003", "黑色柳丁"},
	}
	for _, c := range reject {
		if got := albumScore(c.candidate, c.local); got >= gate {
			t.Errorf("应拦下: albumScore(%q, %q) = %d, 应当 < %d",
				c.candidate, c.local, got, gate)
		}
	}

	if got := albumScore("Bad 25th Anniversary", "Bad"); got < gate {
		t.Errorf("加长版预期是 100 这一档(靠曲目数上限兜底), 实际 albumScore = %d", got)
	}
	if albumPrefetchMaxTracks > 30 {
		t.Errorf("曲目数上限放宽到 %d 了 —— 闸门降到 100 之后,这个上限是挡加长版/合集的唯一一道", albumPrefetchMaxTracks)
	}
}
