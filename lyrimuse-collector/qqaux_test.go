package main

import (
	"strings"
	"testing"
)

func TestQQAuxiliaryPlainToLRCCleansTranslationTrack(t *testing.T) {
	plain := strings.Join([]string{
		"[ti:示例曲目]",
		"[ar:示例歌手]",
		"[kana:1よね1づ1けん1し]",
		"[offset:0]",
		"[00:00.00]QQ音乐享有本翻译作品的著作权",
		"[00:00.39]//",
		"[00:00.79]//",
		"[00:01.19]第一句译文",
		"[00:06.04]第二句 译文里带空格",
		"[00:08.51]第三句译文",
		"[00:10.00]   ",
		"",
	}, "\n")
	got := qqAuxiliaryPlainToLRC(plain)
	want := strings.Join([]string{
		"[offset:0]",
		"[00:01.19]第一句译文",
		"[00:06.04]第二句 译文里带空格",
		"[00:08.51]第三句译文",
	}, "\n")
	if got != want {
		t.Fatalf("清洗结果不对\n实际:\n%s\n期望:\n%s", got, want)
	}
}

func TestQQAuxiliaryPlainToLRCConvertsQRCRomaTrack(t *testing.T) {
	content := strings.Join([]string{
		"[ti:示例曲目]",
		"[offset:0]",
		"[0,529](496,33)",
		"[530,529](970,88)",
		"[1547,1151]yu (1547,223)me (1771,152)na (1924,223)ra (2147,164)ba (2312,386)",
		"[62880,4001]do (62880,303)re (63184,351)ho (63536,167)do (63703,447)",
		"[125001,900]i (125001,184)ma (125185,191)",
	}, "\n")
	xml := `<?xml version="1.0" encoding="utf-8"?>` + "\n" +
		`<QrcInfos><QrcHeadInfo SaveTime="1" Version="1"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="` + content + "\n" + `"/>` + "\n</LyricInfo>\n</QrcInfos>"
	got := qqAuxiliaryPlainToLRC(xml)
	want := strings.Join([]string{
		"[offset:0]",
		"[00:01.547]yu me na ra ba",
		"[01:02.880]do re ho do",
		"[02:05.001]i ma",
	}, "\n")
	if got != want {
		t.Fatalf("QRC 罗马音转逐行 LRC 不对\n实际:\n%s\n期望:\n%s", got, want)
	}
}

func TestQRCToLineLRCKeepsTextParentheses(t *testing.T) {
	got := qrcToLineLRC("[0,529]Lemon - (0,33)米(33,66)津(99,33) ((232,33)よ(265,33)ね(298,33))(497,33)")
	if got != "[00:00.000]Lemon - 米津 (よね)" {
		t.Fatalf("实际 %q", got)
	}
}

func TestQQAuxiliaryPlainToLRCRejectsTooFewLines(t *testing.T) {
	if got := qqAuxiliaryPlainToLRC("[00:00.00]//\n[00:01.19]只有一句\n[00:02.00]只有两句"); got != "" {
		t.Fatalf("两行残片应当被丢弃,实际 %q", got)
	}
	if got := qqAuxiliaryPlainToLRC(""); got != "" {
		t.Fatalf("空输入应返回空串,实际 %q", got)
	}
}

func TestIsQQTranslationNotice(t *testing.T) {
	cases := map[string]bool{
		"QQ音乐享有本翻译作品的著作权":  true,
		"本翻译作品的著作权归QQ音乐所有": true,
		"我在QQ音乐上听到这首歌":     false,
		"著作权":              false,
	}
	for text, want := range cases {
		if got := isQQTranslationNotice(text); got != want {
			t.Errorf("isQQTranslationNotice(%q) = %v, want %v", text, got, want)
		}
	}
}

func TestSplitQRCKanaLine(t *testing.T) {
	content := strings.Join([]string{
		"[ti:示例]",
		"[kana:1よね1づ1けん1し1ゆ(1547,224)め(1771,153)]",
		"[1547,1152]夢(1547,377)な(1924,223)ら(2147,165)ば(2312,387)",
	}, "\n")
	kana, rest := splitQRCKanaLine(content)
	if kana != "[kana:1よね1づ1けん1し1ゆ(1547,224)め(1771,153)]" {
		t.Fatalf("kana 行摘错: %q", kana)
	}
	if strings.Contains(rest, "[kana:") || !strings.Contains(rest, "[1547,1152]") || !strings.Contains(rest, "[ti:示例]") {
		t.Fatalf("剩余正文不对: %q", rest)
	}
	if strings.Contains(qrcToYRC(rest), "kana") {
		t.Fatalf("YRC 里不该有 kana 行")
	}
	if k, r := splitQRCKanaLine("[0,10]a(0,10)"); k != "" || r != "[0,10]a(0,10)" {
		t.Fatalf("没有 kana 行时应原样返回,实际 %q / %q", k, r)
	}
}

func TestAttachKanaLine(t *testing.T) {
	lrc := "[00:00.00]标题\n[00:01.54]夢ならば"
	if got := attachKanaLine(lrc, "[kana:1ゆめ]"); got != "[kana:1ゆめ]\n"+lrc {
		t.Fatalf("实际 %q", got)
	}
	if got := attachKanaLine(lrc, ""); got != lrc {
		t.Fatalf("kana 为空应原样返回,实际 %q", got)
	}
	if got := attachKanaLine("", "[kana:1ゆめ]"); got != "" {
		t.Fatalf("歌词为空应原样返回,实际 %q", got)
	}
	already := "[kana:1あ]\n" + lrc
	if got := attachKanaLine(already, "[kana:1ゆめ]"); got != already {
		t.Fatalf("已带 kana 行不应重复拼,实际 %q", got)
	}
}

func TestLyricConsensusBodyIgnoresMetaTagLines(t *testing.T) {
	plain := "[00:01.54]夢ならば\n[00:02.88]どれほどよかったでしょう"
	withMeta := "[kana:1ゆ(1547,224)め(1771,153)1いま]\n[ti:Lemon]\n[ar:米津玄師]\n[offset:0]\n" + plain
	if got, want := lyricConsensusBody(withMeta), lyricConsensusBody(plain); got != want {
		t.Fatalf("元数据标签行不该进共识正文\n实际 %q\n期望 %q", got, want)
	}
	if lyricConsensusBody("hello world\nsecond line") == "" {
		t.Fatal("无时间戳的纯文本行仍应算正文")
	}
	for line, want := range map[string]bool{
		"[kana:1ゆめ]":      true,
		"  [offset:0]  ":  true,
		"[00:01.54]夢ならば":  false,
		"[Chorus]":        false,
		"[kana:1ゆめ] 夢ならば": false,
		"夢ならば":            false,
	} {
		if got := isLRCMetaTagLine(line); got != want {
			t.Errorf("isLRCMetaTagLine(%q) = %v, want %v", line, got, want)
		}
	}
}
