package main

import "testing"

func TestKugouPlayerWiring(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

	if got := resolvePlayers([]string{"kugou_music"}, ""); !got[playerKugou] {
		t.Errorf("resolvePlayers([kugou_music]) = %v，期望包含 %q（认不出会静默退回自动识别）", got, playerKugou)
	}

	features.Players = map[string]bool{playerKugou: true}
	if got := playerBundleID(playerKugou); got != kugouMusicBundleID {
		t.Errorf("playerBundleID(kugou) = %q，期望 %q", got, kugouMusicBundleID)
	}
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "KuGou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(固定播放器分支) = %q", got)
	}

	if !isKnownPlayerBundleID(kugouMusicBundleID) {
		t.Error("自动识别模式认不出酷狗的 bundle id")
	}
	features.Players = map[string]bool{playerAuto: true}
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "KuGou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(自动识别分支) = %q", got)
	}

	if got := playerNativeLyricSource(playerKugou); got != "kugou" {
		t.Errorf("playerNativeLyricSource(酷狗) = %q，期望 kugou", got)
	}

	ids := map[string]string{
		"apple":   "com.apple.Music",
		"qq":      qqMusicBundleID,
		"netease": neteaseMusicBundleID,
		"spotify": spotifyBundleID,
		"kugou":   kugouMusicBundleID,
	}
	seen := map[string]string{}
	for name, id := range ids {
		if prev, dup := seen[id]; dup {
			t.Errorf("bundle id 撞车: %s 和 %s 都是 %q", prev, name, id)
		}
		seen[id] = name
	}
}

func TestTrustedPlayersWiring(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

	got := resolveTrustedPlayers(map[string]string{
		"  com.foobar.mac  ": "  Foobar2000  ",
		"":                   "空 id 该被丢掉",
		"com.apple.Music":    "内置,该被剔掉",
		qqMusicBundleID:      "内置,该被剔掉",
		kugouMusicBundleID:   "内置,该被剔掉",
		"com.some.player":    "",
	})
	if len(got) != 2 {
		t.Fatalf("清洗后应剩 2 条,实得 %d: %v", len(got), got)
	}
	if got["com.foobar.mac"] != "Foobar2000" {
		t.Errorf("首尾空白没去掉: %q", got["com.foobar.mac"])
	}
	if name, ok := got["com.some.player"]; !ok || name != "" {
		t.Errorf("名字为空的条目该保留(名字只影响标签、不影响准入): %v", got)
	}
	if resolveTrustedPlayers(nil) != nil || resolveTrustedPlayers(map[string]string{}) != nil {
		t.Error("空输入该返回 nil(调用方一律用 m[k] 取值,nil map 是合法零值读取)")
	}

	features.TrustedPlayers = got

	for _, id := range []string{"com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID} {
		if !isAcceptedPlayerBundleID(id) {
			t.Errorf("内置播放器 %q 该被接受", id)
		}
	}
	if !isAcceptedPlayerBundleID("com.foobar.mac") {
		t.Error("信任过的 App 该被接受")
	}
	if !isAcceptedPlayerBundleID("com.some.player") {
		t.Error("名字为空不影响准入")
	}
	if isAcceptedPlayerBundleID("com.apple.Safari") {
		t.Error("陌生 App 默认不该被接受(这条就是「一条垃圾都进不来」)")
	}

	if isKnownPlayerBundleID("com.foobar.mac") {
		t.Error("isKnownPlayerBundleID 只该认内置播放器,不看信任列表")
	}

	if got := mediaPlayerLabel("com.foobar.mac"); got != "Foobar2000 (macOS)" {
		t.Errorf("信任 App 的标签 = %q,期望 Foobar2000 (macOS)", got)
	}
	if got := mediaPlayerLabel("com.some.player"); got != "com.some.player (macOS)" {
		t.Errorf("名字为空时该退回 bundle id,实得 %q", got)
	}
	if got := mediaPlayerLabel("com.apple.Safari"); got != "Apple Music (macOS)" {
		t.Errorf("没信任的 App 走原有兜底,实得 %q", got)
	}
}

func TestTrustedPlaybackNotASong(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	const arc = "company.thebrowser.Browser"
	features.TrustedPlayers = map[string]string{arc: "Arc"}

	if !trustedPlaybackNotASong(arc, "", "") {
		t.Error("artist/album 都空,该判成不是一首歌")
	}

	if !trustedPlaybackNotASong(arc, "Dream in reality", "") {
		t.Error("YouTube 频道名进了 artist 但 album 空,仍该判成不是一首歌")
	}

	if !trustedPlaybackNotASong(arc, "", "某专辑") {
		t.Error("artist 空同样该丢掉")
	}

	if !trustedPlaybackNotASong(arc, "   ", "某专辑") || !trustedPlaybackNotASong(arc, "某歌手", "  ") {
		t.Error("纯空白该按空处理")
	}

	for _, c := range []struct{ artist, album string }{
		{"周杰伦", "七里香"},
		{"方大同", "Soulboy"},
		{"卢广仲", "100种生活"},
	} {
		if trustedPlaybackNotASong(arc, c.artist, c.album) {
			t.Errorf("两个字段都齐的不该被丢掉: %s / %s", c.artist, c.album)
		}
	}

	for _, id := range []string{"com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID} {
		if trustedPlaybackNotASong(id, "", "") {
			t.Errorf("内置播放器 %q 不该被这条守卫影响", id)
		}
	}

	if trustedPlaybackNotASong("com.apple.Safari", "", "") {
		t.Error("没信任过的 App 由准入层负责挡,不该在这条守卫里返回 true")
	}
}
