package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestStrokeMaskSharesContentPadding(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/UI/LyricsOverlayView.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)

	i := strings.Index(body, "private struct OptionalTextStroke")
	if i < 0 {
		t.Fatal("找不到 OptionalTextStroke(被改名了?同步更新这个测试)")
	}
	seg := body[i:]
	if j := strings.Index(seg, "\n}\n"); j > 0 {
		seg = seg[:j]
	}

	if !regexp.MustCompile(`content\s*\n\s*(//[^\n]*\n\s*)*\.padding\(width \* 2\)`).MatchString(seg) &&
		!strings.Contains(seg, ".padding(width * 2)") {
		t.Fatal("OptionalTextStroke 里找不到 content 的 .padding(width * 2)")
	}

	k := strings.Index(seg, "} symbols: {")
	if k < 0 {
		t.Fatal("找不到 Canvas 的 symbols 块")
	}
	sym := seg[k:]
	if !strings.Contains(sym, ".padding(width * 2)") {
		t.Error("描边剪影(symbols 块)缺少 .padding(width * 2) —— " +
			"剪影与 content 不同框,对唱歌(leading/trailing 排版)的描边会整圈偏 2.4pt。" +
			"见本测试顶部注释。")
	}

	if n := strings.Count(seg, ".padding(width * 2)"); n != 2 {
		t.Errorf("期望 content 和 symbols 各一道 .padding(width * 2),实际出现 %d 次 —— "+
			"两道必须成对且同量,否则剪影与内容错位", n)
	}
}
