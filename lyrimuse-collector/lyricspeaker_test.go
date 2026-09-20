package main

import (
	"strings"
	"testing"
)

func TestLyricSplitLabel(t *testing.T) {
	cases := []struct {
		in          string
		label, rest string
		ok          bool
	}{
		{"男：周末守着烤箱", "男", "周末守着烤箱", true},
		{"女: 偏爱年轻女伴", "女", "偏爱年轻女伴", true},
		{"周杰伦：", "周杰伦", "", true},
		{"词：方文山", "词", "方文山", true},
		{"情人节也落单", "", "", false},
		{"Chris Tucker: Oh man", "", "", false},
		{"Baby, I said: hello", "", "", false},
		{"一二三四五六七八九十一：x", "", "", false},
		{"：只有冒号", "", "", false},
	}
	for _, c := range cases {
		label, rest, ok := lyricSplitLabel(c.in)
		if ok != c.ok || label != c.label || rest != c.rest {
			t.Errorf("lyricSplitLabel(%q) = (%q,%q,%v), 期望 (%q,%q,%v)",
				c.in, label, rest, ok, c.label, c.rest, c.ok)
		}
	}
}

func TestLyricSpeakerLabels(t *testing.T) {

	got := lyricSpeakerLabels("[00:01.00]男：一\n[00:02.00]女：二\n")
	if !got["男"] || !got["女"] || len(got) != 2 {
		t.Errorf("已知声部词: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]词：葛大为\n[00:02.00]曲：陶喆\n[00:03.00]真歌词\n")
	if len(got) != 0 {
		t.Errorf("署名标签不该算演唱者: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]周杰伦：\n[00:02.00]一\n[00:03.00]杨瑞代：\n[00:04.00]二\n[00:05.00]周杰伦：\n[00:06.00]三\n")
	if !got["周杰伦"] || !got["杨瑞代"] || len(got) != 2 {
		t.Errorf("人名标记过闸: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]Rap：\n[00:02.00]一\n[00:03.00]Rap2：\n[00:04.00]二\n")
	if len(got) != 0 {
		t.Errorf("两处一次性标记不该算: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]执行制作：甲\n[00:02.00]录音师：乙\n[00:03.00]混音师：丙\n[00:04.00]录音室：丁\n[00:05.00]混音室：戊\n[00:06.00]歌词\n")
	if len(got) != 0 {
		t.Errorf("都不重复的多标签是职员表: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]我说：是的\n[00:02.00]然后她问我：好吗\n[00:03.00]我说：好\n")
	if len(got) != 0 {
		t.Errorf("叙事标签不是演唱者: got %v", got)
	}

	got = lyricSpeakerLabels("[00:01.00]男：一\r\n[00:02.00]女：二\r\n")
	if !got["男"] || !got["女"] {
		t.Errorf("CRLF 切行: got %v", got)
	}
}

func TestLyricConsensusBodyKeepsDuetLyrics(t *testing.T) {

	tagged := "[00:01.00]男：我爱过你笑的脸庞\n[00:02.00]女：时间留不住一句话\n" +
		"[00:03.00]男：我记得曾为你疯狂\n[00:04.00]女：何时过了年少轻狂\n"
	plain := "[00:01.00]我爱过你笑的脸庞\n[00:02.00]时间留不住一句话\n" +
		"[00:03.00]我记得曾为你疯狂\n[00:04.00]何时过了年少轻狂\n"
	a, b := lyricConsensusBody(tagged), lyricConsensusBody(plain)
	if a != b {
		t.Errorf("带标注与不带标注的同一首歌,共识正文应当完全相同\n带标注: %q\n不带:   %q", a, b)
	}
	if a == "" {
		t.Fatal("共识正文被摘空了")
	}

	if j := gramJaccard(lyricGram3Set(a), lyricGram3Set(b)); j < 0.999 {
		t.Errorf("同一首歌跨源相似度应为 1.0, 实际 %.3f", j)
	}
}

func TestLyricConsensusBodyStandaloneMarkers(t *testing.T) {
	lrc := "[00:01.00]周杰伦：\n[00:02.00]没有了联络\n[00:03.00]阿信：\n[00:04.00]电话开始躲\n" +
		"[00:05.00]周杰伦：\n[00:06.00]你什么都没有\n"
	body := lyricConsensusBody(lrc)
	for _, want := range []string{"没有了联络", "电话开始躲", "你什么都没有"} {
		if !strings.Contains(body, want) {
			t.Errorf("共识正文里缺 %q: %q", want, body)
		}
	}
	if strings.Contains(body, "周杰伦") || strings.Contains(body, "阿信") {
		t.Errorf("标签本身不该进共识正文: %q", body)
	}
}

func TestIsCreditOnlyLRCKeepsDuet(t *testing.T) {
	duet := "[00:01.00]男：我爱过你笑的脸庞\n[00:02.00]女：时间留不住一句话\n" +
		"[00:03.00]男：我记得曾为你疯狂\n[00:04.00]女：何时过了年少轻狂\n"
	if isCreditOnlyLRC(duet) {
		t.Error("整份行内前缀的对唱被误判成 credit-only")
	}

	credits := "[00:01.00]作词：甲\n[00:02.00]作曲：乙\n[00:03.00]编曲：丙\n"
	if !isCreditOnlyLRC(credits) {
		t.Error("真职员表应当判废")
	}
}
