package main

import (
	"os"
	"strings"
	"testing"
)

func TestLyricsDecisionPathsHaveChineseLabels(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	src := string(data)

	const fnMarker = "private func pathLabel("
	start := strings.Index(src, fnMarker)
	if start < 0 {
		t.Fatalf("%s 里找不到 pathLabel —— 函数改名了就同步改这个测试", sheet)
	}
	body := src[start:]
	if end := strings.Index(body, "\n    }\n"); end > 0 {
		body = body[:end]
	}
	for _, path := range lyricsDecisionPaths() {
		needle := `case "` + path + `":`
		if !strings.Contains(body, needle) {
			t.Errorf("path %q 在 LyricsDecisionSheet.pathLabel 里没有中文译名(缺 %s)——"+
				"不补的话界面上会直接把这个英文串印给用户看", path, needle)
		}
	}

	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		rest := strings.TrimPrefix(line, `case "`)
		idx := strings.Index(rest, `"`)
		if idx <= 0 {
			continue
		}
		got := rest[:idx]
		found := false
		for _, path := range lyricsDecisionPaths() {
			if path == got {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Swift 里有 case %q 的译名,但 lyricsDecisionPaths() 没登记它 —— 清单漏了", got)
		}
	}
}
