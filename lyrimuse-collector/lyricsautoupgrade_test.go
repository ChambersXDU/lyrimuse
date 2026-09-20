package main

import (
	"testing"
	"time"
)

func TestLyricsAutoUpgradeGate(t *testing.T) {

	stale := enrichEntry{Lyrics: "[00:01.00]x", LyricsScoringVersion: lyricsScoringVersion - 1}
	if !needsLyricsRescore(stale, false, true) {
		t.Error("开着时:打分版本落后应该触发重打分")
	}
	if needsLyricsRescore(stale, false, false) {
		t.Error("关掉之后:不该再因为打分规则升级换掉已有歌词")
	}

	savedFeatures := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(savedFeatures) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "qq": true, "lrclib": true})
	long := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1
	missed := enrichEntry{Lyrics: "[00:01.00]x", LyricsSourcesSeen: []string{"lrclib"}, TS: long}
	if !needsLyricsRetry(missed, false, false, true) {
		t.Error("开着时:有源缺席应该触发升级重搜")
	}
	if needsLyricsRetry(missed, false, false, false) {
		t.Error("关掉之后:不该再自动重搜升级已有歌词")
	}

	empty := enrichEntry{Lyrics: "", LyricsSourcesSeen: []string{"lrclib"}}
	if !needsLyricsFirstFill(empty) {
		t.Error("空歌词条目应该照常走首次填充(跟这个开关无关)")
	}

	manual := enrichEntry{Lyrics: "[00:01.00]x", ManualLyrics: true,
		LyricsScoringVersion: lyricsScoringVersion - 1}
	for _, auto := range []bool{true, false} {
		if needsLyricsRescore(manual, false, auto) {
			t.Errorf("手改过的歌词永远不该被重打分(autoUpgrade=%v)", auto)
		}
		if needsLyricsRetry(manual, false, false, auto) {
			t.Errorf("手改过的歌词永远不该被重搜(autoUpgrade=%v)", auto)
		}
		if needsLyricsRescore(stale, true, auto) {
			t.Errorf("钉过时间轴的永远不该被重打分(autoUpgrade=%v)", auto)
		}
	}
}

func TestLyricsAutoUpgradeDefaultsOn(t *testing.T) {
	if got := boolOr(nil, true); !got {
		t.Error("缺字段时应当默认开启(跟 Swift 侧 lyricsAutoUpgrade = true 对齐)")
	}
	off := false
	if got := boolOr(&off, true); got {
		t.Error("显式写 false 时应当关闭")
	}
}
