package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPinBlocksAutomaticLyricsReselection(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

	stale := enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion - 1}
	if !needsLyricsRescore(stale, false, true) {
		t.Fatal("前提不成立：版本落后的条目本来就该重选，测试用例失效")
	}
	if needsLyricsRescore(stale, true, true) {
		t.Error("已校准的条目不该被 rescore 换掉歌词")
	}

	wrongDur := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", ResolvedDurationSecs: 300,
	}

	confirmedMismatch := durationMismatch(wrongDur.ResolvedDurationSecs, 200)
	if !confirmedMismatch {
		t.Fatal("前提不成立：时长差 33% 该判为 mismatch，测试用例失效")
	}
	if !needsLyricsRetry(wrongDur, confirmedMismatch, false, true) {
		t.Fatal("前提不成立：确认过的时长不匹配本来就该重试，测试用例失效")
	}
	if needsLyricsRetry(wrongDur, confirmedMismatch, true, true) {
		t.Error("已校准的条目不该被「时长对不上」这条路径换掉歌词")
	}

	empty := enrichEntry{}
	if !needsLyricsFirstFill(empty) {
		t.Fatal("前提不成立：空歌词条目本来就该首次填充，测试用例失效")
	}
}

func TestLyricsPinnedRereadsWhenFileChanges(t *testing.T) {
	savedPath := lyricsPinsPath
	t.Cleanup(func() {
		lyricsPinsPath = savedPath
		lyricsPins, lyricsPinsRead, lyricsPinsSize = nil, false, 0
		lyricsPinsMTime = time.Time{}
	})

	path := filepath.Join(t.TempDir(), "pins.json")
	lyricsPinsPath = path
	lyricsPins, lyricsPinsRead, lyricsPinsSize = nil, false, 0
	lyricsPinsMTime = time.Time{}

	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件不存在时不该判成已校准")
	}

	write := func(body string, when time.Time) {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("写 pin 文件失败: %v", err)
		}

		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatalf("改 mtime 失败: %v", err)
		}
	}

	base := time.Now().Add(-time.Hour)
	write(`{"version":1,"pins":{"周杰伦|退后|依然范特西":1787200000}}`, base)
	if !lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件里有这个 key，该判成已校准")
	}
	if lyricsPinned("周杰伦|心雨|叶惠美") {
		t.Error("文件里没有的 key 不该判成已校准")
	}

	write(`{"version":1,"pins":{}}`, base.Add(time.Minute))
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件已经改过（key 被去掉），该按新内容判定")
	}

	write(`{"version":1,"pins":{"周杰伦|退后|依然范特西":1}}`, base.Add(2*time.Minute))
	if !lyricsPinned("周杰伦|退后|依然范特西") {
		t.Fatal("前提不成立：这一步该读到 pin")
	}
	write(`{ 这不是 JSON`, base.Add(3*time.Minute))
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("文件解析失败时该当作空名单，而不是沿用上一次读到的内容")
	}

	lyricsPinsPath = ""
	if lyricsPinned("周杰伦|退后|依然范特西") {
		t.Error("lyricsPinsPath 为空时不该判成已校准")
	}
}
