package main

import "testing"

func TestNativeSourceBonus(t *testing.T) {
	const lrc = "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	score := func(source string, wordTiming bool) int {
		return scoreLyricCandidate("周杰伦", "太阳之子", "", 0,
			lyricCandidate{source: source, lyrics: lrc, hasWordTiming: wordTiming}, false, 0)
	}

	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })

	nativeLyricSources = nil
	base := score("qq", false)
	if got := score("kugou", false); got != base {
		t.Errorf("没有 native 源时不该有来源差异: qq=%d kugou=%d", base, got)
	}

	nativeLyricSources = map[string]bool{"qq": true}
	if got := score("qq", false); got != base+250 {
		t.Errorf("同源该加 250, got %d (base %d)", got, base)
	}
	if got := score("kugou", false); got != base {
		t.Errorf("非同源不该加分, got %d (base %d)", got, base)
	}

	if score("qq", false) >= score("kugou", true) {
		t.Errorf("同源无逐字不该赢过跨源有逐字: qq=%d kugou+yrc=%d",
			score("qq", false), score("kugou", true))
	}

	if score("qq", true) <= score("kugou", true) {
		t.Errorf("同源+逐字该赢: qq=%d kugou=%d", score("qq", true), score("kugou", true))
	}
}

func TestPlayerNativeLyricSource(t *testing.T) {
	cases := map[string]string{
		playerQQMusic: "qq", playerNetease: "netease",

		playerAppleMusic: "", playerSpotify: "", playerAuto: "", "": "",
	}
	for player, want := range cases {
		if got := playerNativeLyricSource(player); got != want {
			t.Errorf("player %q → %q, want %q", player, got, want)
		}
	}
}

func TestPlayerForBundleID(t *testing.T) {
	cases := map[string]string{
		appleMusicBundleID:   playerAppleMusic,
		qqMusicBundleID:      playerQQMusic,
		neteaseMusicBundleID: playerNetease,
		spotifyBundleID:      playerSpotify,
		kugouMusicBundleID:   playerKugou,

		"com.google.Chrome": "",
		"":                  "",
	}
	for bundleID, want := range cases {
		if got := playerForBundleID(bundleID); got != want {
			t.Errorf("playerForBundleID(%q) = %q, want %q", bundleID, got, want)
		}
	}
}

func TestSetNativeLyricSourcesForPlayer(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })

	setNativeLyricSourcesForPlayer(appleMusicBundleID)
	if hasNativeLyricSource() {
		t.Errorf("放 Apple Music 时不该有任何同源加权,got %v", nativeLyricSources)
	}
	for _, src := range []string{"qq", "netease", "kugou"} {
		if isNativeLyricSource(src) {
			t.Errorf("放 Apple Music 时 %q 不该被判成同源", src)
		}
	}

	setNativeLyricSourcesForPlayer(qqMusicBundleID)
	if !isNativeLyricSource("qq") {
		t.Error("放 QQ 音乐时 qq 应当判为同源")
	}
	if isNativeLyricSource("netease") || isNativeLyricSource("kugou") {
		t.Errorf("放 QQ 音乐时只该有 qq 一个,got %v", nativeLyricSources)
	}

	setNativeLyricSourcesForPlayer(kugouMusicBundleID)
	if !isNativeLyricSource("kugou") || isNativeLyricSource("qq") {
		t.Errorf("换到酷狗之后应当恰好只剩 kugou,got %v", nativeLyricSources)
	}

	setNativeLyricSourcesForPlayer(spotifyBundleID)
	if hasNativeLyricSource() {
		t.Errorf("放 Spotify 时不该有任何同源加权,got %v", nativeLyricSources)
	}

	setNativeLyricSourcesForPlayer("com.google.Chrome")
	if hasNativeLyricSource() {
		t.Errorf("认不出的播放器不该有同源加权,got %v", nativeLyricSources)
	}
}

func TestNeedsLyricsRetry_NativeSourceMissedOut(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })
	nativeLyricSources = map[string]bool{"qq": true}

	missed := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq", "lrclib"},
	}
	if !needsLyricsRetry(missed, false, false, true) {
		t.Error("见过同源候选却没选它，该重试（这正是被『有逐字就不重试』挡死的那种）")
	}

	already := missed
	already.LyricsSource = "qq"
	if needsLyricsRetry(already, false, false, true) {
		t.Error("已经是同源，不该重试")
	}

	unseen := missed
	unseen.LyricsSourcesSeen = []string{"kugou", "lrclib"}
	if needsLyricsRetry(unseen, false, false, true) {
		t.Error("同源没出现过，不该为它重试")
	}

	manual := missed
	manual.ManualLyrics = true
	if needsLyricsRetry(manual, false, false, true) {
		t.Error("手改过的歌词绝不能重搜")
	}

	nativeLyricSources = nil
	if needsLyricsRetry(missed, false, false, true) {
		t.Error("没有 native 源时该维持原行为")
	}
}

func TestNeedsLyricsRetry_DurationMismatch(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })
	nativeLyricSources = nil

	entry := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq"},
		ResolvedDurationSecs: 164,
	}
	retryAt := func(e enrichEntry, actual float64) bool {
		return needsLyricsRetry(e, durationMismatch(e.ResolvedDurationSecs, actual), false, true)
	}
	if !retryAt(entry, 246) {
		t.Error("164s 校验的歌词碰上 246s 的真实版本，该重选（哪怕有逐字）")
	}
	if retryAt(entry, 166) {
		t.Error("差 2 秒是标注抖动，不该白跑网络")
	}

	legacy := entry
	legacy.ResolvedDurationSecs = 0
	if retryAt(legacy, 246) {
		t.Error("没记录校验时长的旧条目不触发")
	}

	if retryAt(entry, 0) {
		t.Error("真实时长未知不触发")
	}

	manual := entry
	manual.ManualLyrics = true
	if retryAt(manual, 246) {
		t.Error("手改过的歌词绝不能被时长错配重搜")
	}
}
