package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLyricsEmptyInCacheFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cache.json")

	body := `{
	  "Michael Jackson|Beat It|Thriller": {"lyrics":"[00:01.00]line","lyrics_source":"qq"},
	  "Michael Jackson|Hand-Edited|Thriller": {"lyrics":"[00:01.00]我手改过的","manual_lyrics":true},
	  "南拳妈妈弹头|枫+退后+搁浅 (Live)|周杰伦地表最强世界巡回演唱会 (Live)": {"duration_secs":119.213}
	}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("写测试缓存: %v", err)
	}

	cases := []struct {
		name                 string
		artist, title, album string
		wantEmpty, wantKnown bool
	}{
		{"正常条目:有歌词 → 不放行", "Michael Jackson", "Beat It", "Thriller", false, true},
		{"手改条目:有歌词但没记来源 → **仍然不放行**(这就是复核抓到的反例)",
			"Michael Jackson", "Hand-Edited", "Thriller", false, true},
		{"解析失败的空壳条目:没有歌词 → 放行",
			"南拳妈妈弹头", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)", true, true},
		{"缓存里压根没有这个 key:还没解析过的新歌 → 放行",
			"Michael Jackson", "Smooth Criminal", "Bad", true, true},
	}
	for _, c := range cases {
		empty, known := lyricsEmptyInCacheFile(path, c.artist, c.title, c.album)
		if empty != c.wantEmpty || known != c.wantKnown {
			t.Errorf("%s: lyricsEmptyInCacheFile(%q,%q,%q) = (empty=%v, known=%v), want (%v, %v)",
				c.name, c.artist, c.title, c.album, empty, known, c.wantEmpty, c.wantKnown)
		}
	}

	if _, known := lyricsEmptyInCacheFile(filepath.Join(dir, "nope.json"), "a", "b", "c"); known {
		t.Errorf("文件不存在时 known 必须为 false")
	}
	broken := filepath.Join(dir, "broken.json")
	if err := os.WriteFile(broken, []byte("{ not json"), 0o644); err != nil {
		t.Fatalf("写坏文件: %v", err)
	}
	if _, known := lyricsEmptyInCacheFile(broken, "a", "b", "c"); known {
		t.Errorf("解析不动时 known 必须为 false")
	}

	if _, err := os.Stat(broken + ".corrupt"); err == nil {
		t.Errorf("lyricsEmptyInCacheFile 不得有任何副作用,却把文件挪成了 .corrupt")
	}
	if _, err := os.Stat(broken); err != nil {
		t.Errorf("原文件必须原地不动: %v", err)
	}
}
