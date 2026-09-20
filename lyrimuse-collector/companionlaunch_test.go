package main

import "testing"

func TestShouldCompanionLaunch(t *testing.T) {
	cases := []struct {
		label       string
		justStarted string
		enabled     bool
		running     bool
		want        bool
		wantChecked bool
	}{
		{"播放器刚启动+开关开+Lyrimuse没跑 → 启动", "Music", true, false, true, true},
		{"Lyrimuse 已在跑 → 跳过(本次修复的核心)", "Music", true, true, false, true},
		{"没有播放器发生启动跳变 → 跳过", "", true, false, false, false},
		{"开关关着 → 跳过", "Music", false, false, false, false},
		{"开关关着且已在跑 → 跳过", "Music", false, true, false, false},
		{"手动选定的其它播放器同样适用", "QQMusic", true, false, true, true},
	}
	for _, c := range cases {
		checked := false
		got := shouldCompanionLaunch(c.justStarted, c.enabled, func() bool {
			checked = true
			return c.running
		})
		if got != c.want {
			t.Errorf("%s: shouldCompanionLaunch(%q, %v, →%v) = %v, want %v",
				c.label, c.justStarted, c.enabled, c.running, got, c.want)
		}

		if checked != c.wantChecked {
			t.Errorf("%s: 是否查询运行状态 = %v, want %v(短路语义)", c.label, checked, c.wantChecked)
		}
	}
}

func TestPlayerProcessNameCoversEveryPlayer(t *testing.T) {
	saved := features.Players
	t.Cleanup(func() { features.Players = saved })

	cases := []struct{ player, want string }{
		{playerAppleMusic, "Music"},
		{playerQQMusic, "QQMusic"},
		{playerNetease, "NeteaseMusic"},
		{playerSpotify, "Spotify"},

		{playerKugou, "酷狗音乐"},
	}
	for _, c := range cases {
		if got := playerProcessNameFor(c.player); got != c.want {
			t.Errorf("playerProcessNameFor(%s) = %q, want %q", c.player, got, c.want)
		}
	}

	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	multi := companionLaunchProcessNames()
	for _, want := range []string{"QQMusic", "酷狗音乐"} {
		found := false
		for _, name := range multi {
			if name == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("多选 {qq, kugou} 时 companionLaunchProcessNames() 缺 %q: %v", want, multi)
		}
	}
	if len(multi) != 2 {
		t.Errorf("多选 {qq, kugou} 时应恰好盯 2 个进程名, got %v", multi)
	}

	features.Players = map[string]bool{playerAuto: true}
	auto := companionLaunchProcessNames()
	for _, c := range cases {
		found := false
		for _, name := range auto {
			if name == c.want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("knownPlayerProcessNames 缺 %q(%s),playerAuto 档会漏掉这个播放器", c.want, c.player)
		}
	}

	features.Players = map[string]bool{playerAuto: true, playerQQMusic: true}
	if got := companionLaunchProcessNames(); len(got) != len(knownPlayerProcessNames) {
		t.Errorf("auto+qq 组合应等同于纯 auto(全量列表), got %v", got)
	}
}

func TestCompanionLaunchProcessNamesHonorsChosenPlayers(t *testing.T) {
	defer func() {
		features.Players = map[string]bool{playerAuto: true}
		features.LaunchLyrimuseOnPlayers = nil
	}()

	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	features.LaunchLyrimuseOnPlayers = nil
	if got := companionLaunchProcessNames(); len(got) != 2 {
		t.Errorf("键缺失时应退回盯整个选中集合(2 个), got %v", got)
	}

	features.LaunchLyrimuseOnPlayers = map[string]bool{playerQQMusic: true}
	if got := companionLaunchProcessNames(); len(got) != 1 || got[0] != "QQMusic" {
		t.Errorf("只勾 qq 时应只盯 QQMusic, got %v", got)
	}

	features.LaunchLyrimuseOnPlayers = map[string]bool{playerSpotify: true}
	if got := companionLaunchProcessNames(); len(got) != 0 {
		t.Errorf("勾了未选中的 spotify 不该盯任何进程, got %v", got)
	}

	features.LaunchLyrimuseOnPlayers = map[string]bool{}
	if got := companionLaunchProcessNames(); len(got) != 0 {
		t.Errorf("空列表应一个都不盯, got %v", got)
	}

	features.Players = map[string]bool{playerAuto: true}
	features.LaunchLyrimuseOnPlayers = map[string]bool{playerSpotify: true, playerAppleMusic: true}
	if got := companionLaunchProcessNames(); len(got) != 2 {
		t.Errorf("auto + 勾两个 应盯 2 个, got %v", got)
	}

	if got := resolveLaunchLyrimuseOnPlayers([]string{playerAuto, "bogus", playerNetease}); len(got) != 1 || !got[playerNetease] {
		t.Errorf("resolveLaunchLyrimuseOnPlayers 应只留 netease, got %v", got)
	}
	if got := resolveLaunchLyrimuseOnPlayers(nil); got != nil {
		t.Errorf("nil 应原样透传(表示键缺失), got %v", got)
	}
}

func TestBatchRunningProcesses(t *testing.T) {
	ctx := t.Context()

	emptyRes, err := batchRunningProcesses(ctx, nil)
	if err != nil {
		t.Fatalf("batchRunningProcesses with nil failed: %v", err)
	}
	if len(emptyRes) != 0 {
		t.Fatalf("batchRunningProcesses with nil returned non-empty map: %v", emptyRes)
	}

	bogusNames := []string{"NonExistentProc_12345", "AnotherNonExistentProc_67890"}
	res, err := batchRunningProcesses(ctx, bogusNames)
	if err != nil {
		t.Fatalf("batchRunningProcesses with bogus names failed: %v", err)
	}
	for _, name := range bogusNames {
		if res[name] {
			t.Errorf("expected %s to be false, got true", name)
		}
	}
}

func TestCheckCompanionLaunchBypass(t *testing.T) {
	ctx := t.Context()
	savedEnabled := features.LaunchLyrimuseOnMusicOpen
	savedLastRunning := lastRunningByName
	savedWasEnabled := wasCompanionEnabled
	defer func() {
		features.LaunchLyrimuseOnMusicOpen = savedEnabled
		lastRunningByName = savedLastRunning
		wasCompanionEnabled = savedWasEnabled
	}()

	features.LaunchLyrimuseOnMusicOpen = false
	lastRunningByName = map[string]bool{"Music": true}
	wasCompanionEnabled = true

	checkCompanionLaunch(ctx)
	if len(lastRunningByName) != 0 {
		t.Errorf("checkCompanionLaunch when disabled should clear lastRunningByName, got: %v", lastRunningByName)
	}
	if wasCompanionEnabled {
		t.Errorf("checkCompanionLaunch when disabled should set wasCompanionEnabled to false")
	}
}
