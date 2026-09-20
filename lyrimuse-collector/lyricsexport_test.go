package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestWriteLyricsFileAtomicReplacesWholeFileAndLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "A - B - C.lrc")
	if err := writeLyricsFileAtomic(path, []byte("[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]one")); err != nil {
		t.Fatal(err)
	}
	if err := writeLyricsFileAtomic(path, []byte("[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]two")); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || !strings.HasSuffix(string(got), "two") {
		t.Fatalf("第二次写入应整体替换,实际 %q err=%v", got, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 || entries[0].Name() != "A - B - C.lrc" {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("目录里只该剩目标文件,实际 %v", names)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("权限应补成 0644(跟以前 os.WriteFile 导出的一致),实际 %o", info.Mode().Perm())
	}
}

func TestWriteLyricsFileAtomicFailsCleanly(t *testing.T) {
	dir := t.TempDir()
	if err := writeLyricsFileAtomic(filepath.Join(dir, "missing", "x.lrc"), []byte("x")); err == nil {
		t.Fatal("目标目录不存在应报错")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("失败后不该留任何文件,实际 %d 个", len(entries))
	}
}

func TestIsLyricsTempFile(t *testing.T) {
	cases := map[string]bool{
		"A - B - C.lrc.tmp.123456": true,
		"A - B - C.tr.lrc.tmp.9":   true,
		"A - B - C.yrc.tmp.abc":    true,
		"A - B - C.lrc":            false,
		"A - B - C.tr.lrc":         false,
		"weird.tmp.lrc":            false,
		"weird.tmp.yrc":            false,
		".DS_Store":                false,
	}
	for name, want := range cases {
		if got := isLyricsTempFile(name); got != want {
			t.Errorf("isLyricsTempFile(%q) = %v, want %v", name, got, want)
		}
	}
	for _, name := range []string{"A - B - C.lrc.tmp.123456", "A - B - C.tr.lrc.tmp.9"} {
		if lyricsFileSuffixOf(name) != "" {
			t.Errorf("临时文件 %q 不该被导入分组认成歌词变体", name)
		}
	}
}

func TestImportLyricsFromFilesSweepsTempFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	full := "[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	write("A - B - C.lrc", full)
	write("A - B - C.lrc.tmp.111111", "[ar:A]\n[ti:B]\n[al:C]\n\n[00:01.00]half")
	write("A - B - C.yrc.tmp.222222", "garbage")
	write(".DS_Store", "x")

	savedDir, savedCache := lyricsDir, enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		lyricsDir, enrichCache = savedDir, savedCache
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	lyricsDir = dir
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()

	importLyricsFromFiles()

	entries, _ := os.ReadDir(dir)
	names := map[string]bool{}
	for _, e := range entries {
		names[e.Name()] = true
	}
	if names["A - B - C.lrc.tmp.111111"] || names["A - B - C.yrc.tmp.222222"] {
		t.Fatalf("临时文件应被清扫,实际剩下 %v", names)
	}
	if !names["A - B - C.lrc"] || !names[".DS_Store"] {
		t.Fatalf("正常文件不该被动,实际 %v", names)
	}
	enrichMu.Lock()
	e := enrichCache[enrichKey("A", "B", "C")]
	enrichMu.Unlock()
	if !strings.HasSuffix(e.Lyrics, "three") {
		t.Fatalf("导入应采纳完整的 .lrc 正文而不是临时文件里的半截,实际 %q", e.Lyrics)
	}
}

func TestExportLyricsFilesConcurrentWritesStayWhole(t *testing.T) {
	dir := t.TempDir()
	savedDir, savedCache := lyricsDir, enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		lyricsDir, enrichCache = savedDir, savedCache
		enrichMu.Unlock()
	})
	body := strings.Repeat("[00:01.00]一行歌词正文用来把文件撑长一点,交错截断才看得出来\n", 200)
	enrichMu.Lock()
	lyricsDir = dir
	enrichCache = map[string]enrichEntry{"歌手|歌名|专辑": {Lyrics: body, LyricsSource: "qq"}}
	enrichMu.Unlock()

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			exportLyricsFiles()
		}()
	}
	wg.Wait()

	path := filepath.Join(dir, "歌手 - 歌名 - 专辑.lrc")
	p := parseLyricsFile(path)
	if !p.ok {
		t.Fatalf("并发导出后头部应仍可解析,文件 %s", path)
	}
	if p.body != body {
		t.Fatalf("并发导出后正文应与缓存逐字节相同,实际长度 %d 期望 %d", len(p.body), len(body))
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if isLyricsTempFile(e.Name()) {
			t.Fatalf("并发导出不该留下临时文件: %s", e.Name())
		}
	}
}
