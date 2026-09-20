package main

import "testing"

func TestResolvePlayersMigratesLegacySingleValue(t *testing.T) {

	if got := resolvePlayers(nil, "qq_music"); len(got) != 1 || !got[playerQQMusic] {
		t.Errorf("resolvePlayers(nil, qq_music) = %v，期望迁移成 {qq_music}", got)
	}

	if got := resolvePlayers([]string{}, "spotify"); len(got) != 1 || !got[playerSpotify] {
		t.Errorf("resolvePlayers([], spotify) = %v，期望迁移成 {spotify}", got)
	}

	if got := resolvePlayers([]string{"some_removed_player"}, "netease_music"); len(got) != 1 || !got[playerNetease] {
		t.Errorf("resolvePlayers([认不出的值], netease_music) = %v，期望迁移成 {netease_music}", got)
	}

	if got := resolvePlayers(nil, ""); len(got) != 1 || !got[playerAuto] {
		t.Errorf("resolvePlayers(nil, \"\") = %v，期望兜底 {auto}", got)
	}
}

func TestResolvePlayersAcceptsMultiSelect(t *testing.T) {

	got := resolvePlayers([]string{"qq_music", "kugou_music"}, "apple_music")
	if len(got) != 2 || !got[playerQQMusic] || !got[playerKugou] {
		t.Errorf("resolvePlayers([qq,kugou], apple) = %v，期望恰好 {qq, kugou}（legacy 不该混进来）", got)
	}

	got = resolvePlayers([]string{"qq_music", "some_removed_player"}, "spotify")
	if len(got) != 1 || !got[playerQQMusic] {
		t.Errorf("resolvePlayers([qq,认不出], spotify) = %v，期望只留 {qq}", got)
	}
}

func TestIsTrackedMultiSelect(t *testing.T) {
	saved := features.Players
	t.Cleanup(func() { features.Players = saved })

	newPoller := func(bundle string) *poller {
		return &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Bundle: bundle}}
	}

	features.Players = map[string]bool{playerQQMusic: true}
	if !newPoller(qqMusicBundleID).isTracked() {
		t.Error("单选 qq_music 时,qq 自己的 bundle 该被认")
	}
	if newPoller(neteaseMusicBundleID).isTracked() {
		t.Error("单选 qq_music 时,网易云的 bundle 不该被认")
	}

	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	if !newPoller(qqMusicBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,qq 该被认")
	}
	if !newPoller(kugouMusicBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,kugou 该被认")
	}
	if newPoller(spotifyBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,没选中的 spotify 不该被认")
	}

	features.Players = map[string]bool{playerQQMusic: true, playerAuto: true}
	if !newPoller(spotifyBundleID).isTracked() {
		t.Error("多选 {qq,auto} 时,auto 该把内置的 spotify 也认下来(超集语义)")
	}
	if newPoller("com.apple.Safari").isTracked() {
		t.Error("多选 {qq,auto} 时,没信任过的陌生 App 仍不该被认")
	}
}

func TestIsTrackedMultiSelectHonorsTrustedPlayersWithoutAuto(t *testing.T) {
	savedPlayers, savedTrusted := features.Players, features.TrustedPlayers
	t.Cleanup(func() { features.Players, features.TrustedPlayers = savedPlayers, savedTrusted })

	const chrome = "com.google.Chrome"
	features.Players = map[string]bool{playerQQMusic: true}
	features.TrustedPlayers = map[string]string{chrome: "Chrome"}

	trusted := &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: chrome}}
	if !trusted.isTracked() {
		t.Error("没勾自动识别时,信任列表里的浏览器(网页播放器卡配对)仍应被认")
	}

	untrusted := &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: "com.apple.Safari"}}
	if untrusted.isTracked() {
		t.Error("没被信任过的 App 不该因为这条新路径被放行")
	}

	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}
	viaProxy := &poller{cfg: &config{}, cur: snapshot{
		Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: "com.apple.WebKit.GPU"}}
	if !viaProxy.isTracked() {
		t.Error("信任了 Safari 之后,它的媒体代理进程 com.apple.WebKit.GPU 也该被认")
	}
}

func TestIsTrustedPlayerBundleID(t *testing.T) {
	saved := features.TrustedPlayers
	t.Cleanup(func() { features.TrustedPlayers = saved })

	features.TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if !isTrustedPlayerBundleID("com.google.Chrome") {
		t.Error("信任列表里的 bundle id 该被认")
	}
	if isTrustedPlayerBundleID("com.apple.Safari") {
		t.Error("没信任过的 bundle id 不该被认")
	}
	if isTrustedPlayerBundleID(qqMusicBundleID) {
		t.Error("isTrustedPlayerBundleID 只回答信任这一半,内置播放器不该被它认下来" +
			"(那是 isAcceptedPlayerBundleID/isKnownPlayerBundleID 的职责)")
	}

	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}
	if !isTrustedPlayerBundleID("com.apple.WebKit.GPU") {
		t.Error("信任 Safari 之后,它的媒体代理进程 com.apple.WebKit.GPU 该经别名表被认")
	}
}
