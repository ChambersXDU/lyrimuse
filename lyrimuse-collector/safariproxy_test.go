package main

import (
	"os"
	"strings"
	"testing"
)

func TestSafariMediaProxyTrustResolution(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}

	const proxy = "com.apple.WebKit.GPU"

	t.Run("信任判定经代理别名解析", func(t *testing.T) {
		if !isTrustedPlayerBundleID(proxy) {
			t.Error("WebKit.GPU 该按宿主 Safari 算成受信任")
		}
	})

	t.Run("notASong 守卫对代理进程同样生效", func(t *testing.T) {

		if !trustedPlaybackNotASong(proxy, "某个频道名", "") {
			t.Error("Safari(代理进程)播 album 为空的内容,该判成不是一首歌")
		}

		if trustedPlaybackNotASong(proxy, "王力宏", "十八般武藝") {
			t.Error("字段齐全的真歌不该被丢掉")
		}
	})

	t.Run("media_player 标签按宿主名报,不谎报 Apple Music", func(t *testing.T) {
		if got := mediaPlayerLabel(proxy); got != "Safari (macOS)" {
			t.Errorf("Safari 代理进程的标签 = %q,期望 Safari (macOS)", got)
		}
	})

	t.Run("Safari 没被信任时代理进程照旧不认", func(t *testing.T) {
		features.TrustedPlayers = map[string]string{}
		defer func() { features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"} }()
		if isTrustedPlayerBundleID(proxy) {
			t.Error("宿主不在信任表里时代理进程也不该被信任")
		}
		if trustedPlaybackNotASong(proxy, "", "") {
			t.Error("没信任过的由准入层负责挡,这条守卫该返回 false")
		}
	})
}

func TestNoNakedTrustedPlayersLookupInSystemGo(t *testing.T) {
	src, err := os.ReadFile("system.go")
	if err != nil {
		t.Fatalf("读 system.go: %v", err)
	}

	n := 0
	for _, line := range strings.Split(string(src), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		n += strings.Count(line, "features.TrustedPlayers[bundleID]")
	}
	if n > 1 {
		t.Errorf("system.go 里出现 %d 处 features.TrustedPlayers[bundleID] 裸查,只允许 "+
			"isTrustedPlayerBundleID 内部那 1 处——新代码请改调 isTrustedPlayerBundleID,"+
			"否则 Safari(媒体代理进程 com.apple.WebKit.GPU)会在你的判定里恒不受信任", n)
	}
}
