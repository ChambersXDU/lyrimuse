package main

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

func TestScoringVersionMirroredInApp(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	m := regexp.MustCompile(`currentLyricsScoringVersion\s*=\s*(\d+)`).FindStringSubmatch(string(data))
	if m == nil {
		t.Fatalf("%s 里找不到 currentLyricsScoringVersion —— 改名了就同步改这个测试", sheet)
	}
	mirrored, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("镜像值不是整数: %q", m[1])
	}
	if mirrored != lyricsScoringVersion {
		t.Errorf("打分版本两边不一致: Go lyricsScoringVersion=%d, App currentLyricsScoringVersion=%d —— "+
			"改打分公式时两处要一起改,否则 App 的「旧打分算法」标记会静默失效",
			lyricsScoringVersion, mirrored)
	}
}
