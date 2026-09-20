package main

import (
	"os"
	"strings"
	"testing"
)

func TestShouldGenerateHelperRoma(t *testing.T) {
	cases := []struct {
		name  string
		entry enrichEntry
		want  bool
	}{
		{"日文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]君の名は"}, true},
		{"韩文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]세상의 모서리"}, true},
		{"中文且没有罗马音 → 要生成",
			enrichEntry{Lyrics: "[00:01.00]我爱你"}, true},

		{"已有罗马音 → 绝不覆盖",
			enrichEntry{Lyrics: "[00:01.00]君の名は", LyricsRoma: "[00:01.00]existing"}, false},
		{"没有歌词正文 → 不生成",
			enrichEntry{Lyrics: ""}, false},

		{"纯拉丁歌词 → 不值得起子进程",
			enrichEntry{Lyrics: "[00:01.00]I'll be there"}, false},
	}
	for _, c := range cases {
		e := c.entry
		if got := e.shouldGenerateHelperRoma(); got != c.want {
			t.Errorf("%s: shouldGenerateHelperRoma() = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestMaybeGenerateRomaPrefersJyutping(t *testing.T) {
	e := enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你"}
	e.maybeGenerateRoma()
	if e.LyricsRoma == "" {
		t.Fatal("粤语条目走完 maybeGenerateRoma 之后 LyricsRoma 仍为空,粤拼那一步没跑")
	}
	if !strings.Contains(e.LyricsRoma, "ngo5") {
		t.Errorf("粤语条目拿到的不是粤拼: %q", e.LyricsRoma)
	}
	if e.shouldGenerateHelperRoma() {
		t.Error("粤拼已经填好之后,helper 的闸门仍然是开的 —— 顺序或判据错了,粤语歌会被通用音译覆盖")
	}

	mandarin := enrichEntry{SongLanguage: songLanguageMandarin, Lyrics: "[00:01.00]我爱你"}
	mandarin.maybeGenerateJyutpingRoma()
	if mandarin.LyricsRoma != "" {
		t.Errorf("国语歌不该被粤拼填: %q", mandarin.LyricsRoma)
	}
	if !mandarin.shouldGenerateHelperRoma() {
		t.Error("国语歌应该交给 helper 生成拼音,闸门却是关的")
	}
}

func TestApplyCLIsMarkEnrichDirty(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	checked := 0
	for _, ent := range entries {
		name := ent.Name()
		if !strings.HasSuffix(name, "cli.go") {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		src := string(raw)

		if !strings.Contains(src, "enrichCache[") || !strings.Contains(src, "saveEnrichCache()") {
			continue
		}
		checked++
		if !strings.Contains(src, "enrichDirty = true") {
			t.Errorf("%s 改了 enrichCache 又调 saveEnrichCache,却没有置 enrichDirty —— "+
				"saveEnrichCache 会直接 return,表现是静默不落盘", name)
		}
	}

	if checked < 2 {
		t.Errorf("只扫到 %d 个符合形状的 CLI,判据可能已经失效", checked)
	}
}
