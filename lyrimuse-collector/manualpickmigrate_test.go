package main

import (
	"encoding/json"
	"testing"
)

const (

	goldenPickA   = "[ti:测试]\n[00:01.00]第一句\n[00:05.00]第二句\n"
	goldenPickB   = "[ar:某人]\r\n[offset:120]\r\n[00:02.34]第一句  \r\n\r\n[00:09.99][01:20.00]第二句\t\r\n"
	goldenPickSHA = "13ec24ce7207"

	goldenPickC = "[00:01.00]第一句\n[00:05.00]完全不同的第二句\n"
)

func TestManualPickFingerprintMatchesSwift(t *testing.T) {
	if got := manualPickFingerprint(goldenPickA); got != goldenPickSHA {
		t.Errorf("A: got %q, want %q —— 跟 Swift 侧的口径漂开了", got, goldenPickSHA)
	}

	if got := manualPickFingerprint(goldenPickB); got != goldenPickSHA {
		t.Errorf("B(同一份词、排版全变): got %q, want %q —— 规范化不该改变指纹,"+
			"否则 collector 启动时的重排会让开关静默失效", got, goldenPickSHA)
	}
	if manualPickFingerprint(goldenPickC) == goldenPickSHA {
		t.Error("C 换了词却算出同一个指纹 —— 真正的『被换掉』判不出来了")
	}
	if got := manualPickFingerprint("[ti:只有元数据]\n\n"); got != "" {
		t.Errorf("归一化后没有词该给空串(= 没有留痕), got %q", got)
	}
	if got := manualPickFingerprint(""); got != "" {
		t.Errorf("空正文该给空串, got %q", got)
	}
}

func TestMigrateManualPickMarks(t *testing.T) {
	lyrics := "[00:01.00]x\n"
	want := manualPickFingerprint(lyrics)

	cases := []struct {
		name    string
		entry   enrichEntry
		wantSHA string
	}{{
		name:    "正常转换:当前内容仍来自他选的源",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease"},
		wantSHA: want,
	}, {

		name:    "来源已经换掉:只清字段,不写标记",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "kugou", LyricsSourceChoice: "netease"},
		wantSHA: "",
	}, {

		name:    "已经锁着的:不补留痕(否则手改过的歌会变得可被批量解锁)",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease", ManualLyrics: true},
		wantSHA: "",
	}, {
		name:    "没有正文:没东西可指纹",
		entry:   enrichEntry{LyricsSource: "netease", LyricsSourceChoice: "netease"},
		wantSHA: "",
	}, {

		name:    "已有留痕:不覆盖",
		entry:   enrichEntry{Lyrics: lyrics, LyricsSource: "netease", LyricsSourceChoice: "netease", ManualPickSHA: "keepme"},
		wantSHA: "keepme",
	}}

	enrichCache = map[string]enrichEntry{}
	for _, c := range cases {
		enrichCache[c.name] = c.entry
	}

	enrichCache["无关条目"] = enrichEntry{Lyrics: lyrics, LyricsSource: "qq"}
	enrichPath = t.TempDir() + "/cache.json"

	migrateManualPickMarks()

	for _, c := range cases {
		got := enrichCache[c.name]
		if got.ManualPickSHA != c.wantSHA {
			t.Errorf("%s: ManualPickSHA = %q, want %q", c.name, got.ManualPickSHA, c.wantSHA)
		}
		if got.LyricsSourceChoice != "" {
			t.Errorf("%s: lyrics_source_choice 没清掉(%q) —— 这个中间态已被推翻,留着仍是一道隐形源约束",
				c.name, got.LyricsSourceChoice)
		}
	}
	if e := enrichCache["无关条目"]; e.ManualPickSHA != "" {
		t.Errorf("没有旧字段的条目被误改了: %q", e.ManualPickSHA)
	}

	before, err := json.Marshal(enrichCache)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	migrateManualPickMarks()
	after, err := json.Marshal(enrichCache)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(before) != string(after) {
		t.Error("不幂等:第二遍还在改动缓存")
	}
}
