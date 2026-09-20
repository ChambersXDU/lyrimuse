package main

import (
	"os"
	"strings"
	"testing"
)

func TestLyricScoreTermKindsHaveChineseLabels(t *testing.T) {
	const svc = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchService.swift"
	data, err := os.ReadFile(svc)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", svc, err)
	}
	src := string(data)
	for _, kind := range lyricScoreTermKinds() {
		needle := `case "` + kind + `":`

		if !strings.Contains(src, needle) && !strings.Contains(src, `case "`+kind+`": return`) {
			t.Errorf("打分项 %q 在 LyricsSearchService.ScoreTerm.label 里没有中文译名——"+
				"不补的话「解析决策」/「搜索候选」弹窗会把这个英文串直接印给用户看", kind)
		}
	}
}
