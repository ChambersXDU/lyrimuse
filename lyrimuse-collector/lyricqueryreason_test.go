package main

import (
	"os"
	"strings"
	"testing"
)

func TestLyricQueryReasonsHaveChineseLabels(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	src := string(data)

	const fnMarker = "private func queryReasonLabel("
	start := strings.Index(src, fnMarker)
	if start < 0 {
		t.Fatalf("%s 里找不到 queryReasonLabel —— 函数改名了就同步改这个测试", sheet)
	}
	body := src[start:]
	if end := strings.Index(body, "\n    }\n"); end > 0 {
		body = body[:end]
	}

	for _, reason := range lyricQueryReasons() {
		needle := `case "` + reason + `":`
		if !strings.Contains(body, needle) {
			t.Errorf("查询来路 %q 在 LyricsDecisionSheet.queryReasonLabel 里没有中文译名(缺 %s)——"+
				"不补的话界面上会直接把这个英文串印给用户看", reason, needle)
		}
	}

	if !strings.Contains(body, `case "":`) {
		t.Error(`queryReasonLabel 缺 case ""(首轮)—— 没有它首轮那一行会渲染成「歌手 - 曲名（）」`)
	}

	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		rest := strings.TrimPrefix(line, `case "`)
		idx := strings.Index(rest, `"`)
		if idx < 0 {
			continue
		}
		got := rest[:idx]
		if got == "" {
			continue
		}
		found := false
		for _, reason := range lyricQueryReasons() {
			if reason == got {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Swift 里有 case %q 的译名,但 lyricQueryReasons() 没登记它 —— 清单漏了", got)
		}
	}
}

func TestLyricQueryLogIsWiredIntoEveryRound(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{

		"lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), sortedLyricSourceOnly(ctx))",

		"withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)",
		"aliasReason := lyricQueryReasonAliasMissing",
		"withLyricQueryReason(ctx, lyricQueryReasonPrimaryVar)",
		"titleCtx := withLyricQueryReason(ctx, retryMethod)",

		"e.LyricsDecision.QueriesTried = queries.queries()",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q —— 少一处标注,决策留痕里那一轮就会被记成「首轮」", needle)
		}
	}
}

func TestRetryMethodMatchesQueryReasonConstants(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, want := range []string{lyricQueryReasonTitleAlbum, lyricQueryReasonTitleSearch} {
		if !strings.Contains(src, `"`+want+`"`) {
			t.Errorf("enrich.go 里找不到 retryMethod 字面量 %q —— 它跟 lyricQueryReason* 常量必须逐字相同", want)
		}
	}
}
