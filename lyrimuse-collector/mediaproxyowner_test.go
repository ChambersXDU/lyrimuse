package main

import "testing"

func TestMediaProxyOwnerAcceptance(t *testing.T) {
	const webkit = "com.apple.WebKit.GPU"
	const safari = "com.apple.Safari"

	saved := features.TrustedPlayers
	defer func() { features.TrustedPlayers = saved }()

	features.TrustedPlayers = map[string]string{safari: "Safari"}
	if !isAcceptedPlayerBundleID(webkit) {
		t.Error("信任了 Safari,WebKit 媒体进程该被采纳")
	}

	features.TrustedPlayers = map[string]string{}
	if isAcceptedPlayerBundleID(webkit) {
		t.Error("没信任 Safari 时不该放行 WebKit 媒体进程")
	}

	features.TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if isAcceptedPlayerBundleID(webkit) {
		t.Error("信任 Chrome 不该顺带放行 WebKit 媒体进程")
	}

	features.TrustedPlayers = map[string]string{webkit: ""}
	if isAcceptedPlayerBundleID(safari) {
		t.Error("别名必须单向:信任代理进程不代表 Safari 本身被信任")
	}

	if _, ok := mediaProxyOwners["com.google.Chrome"]; ok {
		t.Error("Chromium 系报自己的 bundle id,不该出现在代理表里")
	}
	if mediaProxyOwners[webkit] != safari {
		t.Errorf("WebKit 媒体进程的宿主该是 %q", safari)
	}
}
