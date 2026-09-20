package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestParseYTMusicAdVerdict(t *testing.T) {
	cases := []struct {
		name, raw string
		want      ytmusicAdVerdict
	}{

		{"真实广告样本(三条全中)", "1|1|1", ytmusicAdIsAd},

		{"真实歌曲样本(三条全灭)", "0|0|0", ytmusicAdIsSong},

		{"只有 ad-showing 命中", "1|0|0", ytmusicAdIsAd},
		{"只有广告徽章命中", "0|1|0", ytmusicAdIsAd},
		{"只有裸标题命中", "0|0|1", ytmusicAdIsAd},

		{"NOTFOUND", "NOTFOUND", ytmusicAdUnknown},
		{"空输出", "", ytmusicAdUnknown},
		{"只有空白", "   \n", ytmusicAdUnknown},

		{"字段数不对(2 个)", "1|0", ytmusicAdUnknown},

		{"4 段:第四段是专辑名,不影响判定", "1|0|0|某专辑", ytmusicAdIsAd},
		{"非 0/1", "1|x|0", ytmusicAdUnknown},
		{"true/false 不认", "true|false|false", ytmusicAdUnknown},

		{"带外层引号的广告", "\"1|1|1\"", ytmusicAdIsAd},
		{"带外层引号+换行的歌曲", "\"0|0|0\"\n", ytmusicAdIsSong},
	}
	for _, c := range cases {
		if got := parseYTMusicAdVerdict(c.raw); got != c.want {
			t.Errorf("%s: parseYTMusicAdVerdict(%q) = %v, want %v", c.name, c.raw, got, c.want)
		}
	}
}

func TestBrowserScriptFamily(t *testing.T) {
	chromium := []string{"com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser"}
	for _, id := range chromium {
		if got := browserScriptFamily(id); got != "chromium" {
			t.Errorf("%s 应该是 chromium, got %q", id, got)
		}
	}
	if got := browserScriptFamily("com.apple.Safari"); got != "safari" {
		t.Errorf("Safari 方言判错: %q", got)
	}

	for _, id := range []string{"org.mozilla.firefox", "com.apple.Music", "", "com.whatever.app"} {
		if got := browserScriptFamily(id); got != "" {
			t.Errorf("%q 不该有方言, got %q", id, got)
		}
	}
}

func TestBuildYTMusicAdAppleScript(t *testing.T) {
	for _, family := range []string{"chromium", "safari"} {
		s := buildYTMusicAdAppleScript("com.google.Chrome", family)
		if s == "" {
			t.Fatalf("%s: 生成了空脚本", family)
		}

		if !strings.Contains(s, `tell application id "com.google.Chrome"`) {
			t.Errorf("%s: 应该用 `tell application id`", family)
		}

		if !strings.Contains(s, ytmusicHostMarker) {
			t.Errorf("%s: 没有按 %s 过滤标签页", family, ytmusicHostMarker)
		}

		if n := strings.Count(s, "with timeout of"); n != 2 {
			t.Errorf("%s: `with timeout` 出现 %d 次, want 2", family, n)
		}
		if n := strings.Count(s, "end timeout"); n != 2 {
			t.Errorf("%s: `end timeout` 出现 %d 次, want 2", family, n)
		}

		if !strings.Contains(s, "with timeout of 4 seconds") {
			t.Errorf("%s: 超时秒数没有跟常量对齐", family)
		}

		if strings.Count(s, "end try") < 2 {
			t.Errorf("%s: 缺少 try…end try 包裹", family)
		}
		if !strings.Contains(s, `return "NOTFOUND"`) {
			t.Errorf("%s: 没有兜底返回 NOTFOUND", family)
		}
	}

	chromium := buildYTMusicAdAppleScript("com.google.Chrome", "chromium")
	safari := buildYTMusicAdAppleScript("com.apple.Safari", "safari")
	if !strings.Contains(chromium, "javascript \"") {
		t.Error("chromium 应该用 `execute … javascript`")
	}
	if strings.Contains(chromium, "do JavaScript") {
		t.Error("chromium 不该出现 Safari 的 `do JavaScript`")
	}
	if !strings.Contains(safari, "do JavaScript") {
		t.Error("safari 应该用 `do JavaScript`")
	}
	if strings.Contains(safari, "execute (") {
		t.Error("safari 不该出现 Chromium 的 `execute (…) javascript`")
	}

	if s := buildYTMusicAdAppleScript("com.google.Chrome", "gecko"); s != "" {
		t.Errorf("未知方言应返回空串, got %d 字节", len(s))
	}
}

func TestYTMusicAdProbeJSHasNoDoubleQuotes(t *testing.T) {
	if strings.Contains(ytmusicAdProbeJS, "\"") {
		t.Error("JS 源码里出现了双引号 —— 嵌进 AppleScript 会被打坏(见 ytmusicad.go 头注)")
	}

	for _, marker := range []string{"ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND",
		"browse/MPREb", "ytmusic-player-bar"} {
		if !strings.Contains(ytmusicAdProbeJS, marker) {
			t.Errorf("JS 里缺少 %q", marker)
		}
	}

	if !strings.Contains(ytmusicAdProbeJS, "+ '|' +") {
		t.Error("JS 应该返回竖线分隔的裸文本")
	}
}

func TestTrustedPlaybackRejectedShortCircuits(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	const chrome = "com.google.Chrome"
	features.TrustedPlayers = map[string]string{chrome: "Google Chrome"}
	resetYTMusicAdCacheForTest(t)

	if rejected, _ := trustedPlaybackRejected(context.Background(), "com.apple.Music", "", "", ""); rejected {
		t.Error("内置播放器不该被这条守卫拒掉")
	}

	rejected, patch := trustedPlaybackRejected(context.Background(), chrome, "周杰伦", "七里香", "枫")
	if rejected {
		t.Error("artist+album 齐全的不该被拒")
	}

	if patch != "" {
		t.Errorf("上游有专辑名时不该给补丁, got %q", patch)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	start := time.Now()
	if rejected, _ := trustedPlaybackRejected(ctx, chrome, "", "", "某广告"); !rejected {
		t.Error("artist 为空该直接拒")
	}
	if el := time.Since(start); el > 200*time.Millisecond {
		t.Errorf("artist 为空这一档不该发起 AppleScript(耗时 %v)", el)
	}

	rejected2, patch2 := trustedPlaybackRejected(ctx, chrome, "KAO Hong Kong", "", "Liese Jelly to Bubble 全新登場")
	if !rejected2 {
		t.Error("复核读不到时必须 fail-closed 拒掉,不能放行")
	}

	if patch2 != "" {
		t.Errorf("被拒时不该给补丁, got %q", patch2)
	}
}

func TestParseYTMusicAdProbeAlbum(t *testing.T) {
	cases := []struct {
		name, raw, want string
	}{
		{"读到专辑名", "0|0|0||Already Gone", "Already Gone"},
		{"页面上没读到 → 空串(不是解析失败)", "0|0|0||", ""},
		{"只有三段(旧形状)也解得出", "0|0|0", ""},

		{"专辑名里自带 | 原样保留", "0|0|0||A|B", "A|B"},
		{"最后一段是文本不是标志位", "1|0|0||0", "0"},

		{"计数段坏了不影响专辑名", "0|0|0|abc|Already Gone", "Already Gone"},
		{"带计数时专辑名照常在最后一段", "1|1|0|1/2|Already Gone", "Already Gone"},
		{"两端空白削掉", "0|0|0||  Already Gone  ", "Already Gone"},

		{"中间换行压成空格", "0|0|0||Already\nGone", "Already Gone"},
		{"NOTFOUND 没有专辑名", "NOTFOUND", ""},
		{"形状不对时不给专辑名", "1|x|0|某专辑", ""},
	}
	for _, c := range cases {
		if _, got := parseYTMusicAdProbe(c.raw); got != c.want {
			t.Errorf("%s: parseYTMusicAdProbe(%q) album = %q, want %q", c.name, c.raw, got, c.want)
		}
	}
}

func TestYTMusicAlbumPatch(t *testing.T) {
	cases := []struct {
		name, reported string
		verdict        ytmusicAdVerdict
		probed, want   string
	}{
		{"上游报空 + 是歌 + 探针有值 → 补", "", ytmusicAdIsSong, "Already Gone", "Already Gone"},
		{"上游全是空白同样算空", "   ", ytmusicAdIsSong, "Already Gone", "Already Gone"},

		{"上游已有专辑名 → 一个字都不动", "The Essential Michael Jackson", ytmusicAdIsSong, "别的", ""},

		{"判定是广告 → 不补", "", ytmusicAdIsAd, "Already Gone", ""},
		{"还没探到 → 不补", "", ytmusicAdUnknown, "Already Gone", ""},
		{"探针读到的是空白 → 不补", "", ytmusicAdIsSong, "   ", ""},
	}
	for _, c := range cases {
		if got := ytmusicAlbumPatch(c.reported, c.verdict, c.probed); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestYTMusicAdCacheKeyedByTrack(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	ytmusicAdMu.Lock()
	ytmusicAdKey = "com.google.Chrome\x00Queen\x00Another One Bites The Dust"
	ytmusicAdVal = ytmusicAdIsSong
	ytmusicAdAt = time.Now()
	ytmusicAdMu.Unlock()

	ctx := context.Background()

	shortCtx, cancel := context.WithTimeout(ctx, time.Nanosecond)
	defer cancel()
	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); got != ytmusicAdIsSong {
		t.Errorf("同一曲目该命中缓存, got %v", got)
	}

	ytmusicAdMu.Lock()
	ytmusicAdAlbum = "A Night at the Opera"
	ytmusicAdMu.Unlock()
	if _, al := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); al != "A Night at the Opera" {
		t.Errorf("命中缓存时该带回专辑名, got %q", al)
	}

	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "KAO Hong Kong\x00Liese"); got != ytmusicAdUnknown {
		t.Errorf("换曲目该绕过缓存, got %v", got)
	}

	ytmusicAdMu.Lock()
	ytmusicAdAt = time.Now().Add(-ytmusicAdMaxAge - time.Second)
	ytmusicAdMu.Unlock()
	if got, _ := ytmusicAdProbe(shortCtx, "com.google.Chrome", "Queen\x00Another One Bites The Dust"); got != ytmusicAdUnknown {
		t.Errorf("缓存过期该重探, got %v", got)
	}
}

func TestYTMusicAdUnknownNotCached(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	_, _ = ytmusicAdProbe(ctx, "com.google.Chrome", "某歌手\x00某歌名")
	ytmusicAdMu.Lock()
	defer ytmusicAdMu.Unlock()
	if ytmusicAdKey != "" {
		t.Errorf("unknown 不该被写进缓存, key = %q", ytmusicAdKey)
	}
}

func TestYTMusicAdProbeSkipsNonBrowsers(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	for _, id := range []string{"com.apple.Music", "org.mozilla.firefox", "com.whatever"} {
		start := time.Now()
		if got, _ := ytmusicAdProbe(context.Background(), id, "a\x00b"); got != ytmusicAdUnknown {
			t.Errorf("%s 应该 unknown, got %v", id, got)
		}
		if el := time.Since(start); el > 200*time.Millisecond {
			t.Errorf("%s 不该起 osascript(耗时 %v)", id, el)
		}
	}
}

func resetYTMusicAdCacheForTest(t *testing.T) {
	t.Helper()
	clear := func() {
		ytmusicAdMu.Lock()
		ytmusicAdKey, ytmusicAdVal, ytmusicAdAlbum, ytmusicAdAt = "", ytmusicAdUnknown, "", time.Time{}
		ytmusicAdMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

func TestYTMusicAdReuseWindow(t *testing.T) {
	if got := ytmusicAdReuseWindow(ytmusicAdIsAd); got != ytmusicAdRefreshWhenAd {
		t.Errorf("广告判定的复用窗口 = %v, want %v", got, ytmusicAdRefreshWhenAd)
	}
	if ytmusicAdRefreshWhenAd > 5*time.Second {
		t.Errorf("广告判定复用窗口 %v 太长:广告只有 5～30 秒,前贴片一过要尽快放行", ytmusicAdRefreshWhenAd)
	}
	if got := ytmusicAdReuseWindow(ytmusicAdIsSong); got != ytmusicAdMaxAge {
		t.Errorf("歌曲判定的复用窗口 = %v, want %v(稳态播放期间不白烧 AppleScript)", got, ytmusicAdMaxAge)
	}
	if ytmusicAdReuseWindow(ytmusicAdIsAd) >= ytmusicAdReuseWindow(ytmusicAdIsSong) {
		t.Error("广告档的复用窗口必须比歌档短")
	}

	if ytmusicAdReuseWindow(ytmusicAdUnknown) > ytmusicAdMaxAge {
		t.Error("unknown 的复用窗口不该超过歌档")
	}
}
