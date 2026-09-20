package main

import (
	"fmt"
	"strings"
	"unicode"
)

var lyricSoloMarkers = []string{
	"男声", "女声", "男合", "女合", "男", "女", "Male", "Female", "M", "F",
}
var lyricGroupMarkers = []string{
	"合唱", "齐唱", "伴唱", "男女", "合", "众", "齐",
	"白", "旁白", "念", "说", "对白", "口白",
	"Both", "All", "Duet", "Chorus", "Together",
}

var lyricAnonymousMarkers = func() []string {
	var out []string
	for i := 1; i <= 8; i++ {
		out = append(out, fmt.Sprintf("v%d", i), fmt.Sprintf("V%d", i))
	}
	return out
}()

var lyricKnownSpeakerSet = func() map[string]bool {
	m := map[string]bool{}
	for _, group := range [][]string{lyricSoloMarkers, lyricGroupMarkers, lyricAnonymousMarkers} {
		for _, s := range group {
			m[s] = true
		}
	}
	return m
}()

var lyricLabelBreakers = func() map[rune]bool {
	m := map[rune]bool{}
	for _, r := range " \t　，,。.！!？?；;（()）[]【】「」、…—-\"'“”‘’" {
		m[r] = true
	}
	return m
}()

const lyricMaxLabelRunes = 10

func lyricSplitLabel(text string) (label, rest string, ok bool) {
	rs := []rune(strings.TrimLeft(text, " \t　"))
	for i, r := range rs {
		if r == '：' || r == ':' {
			if i == 0 {
				return "", "", false
			}
			return string(rs[:i]), strings.TrimSpace(string(rs[i+1:])), true
		}
		if lyricLabelBreakers[r] || i >= lyricMaxLabelRunes {
			return "", "", false
		}
	}
	return "", "", false
}

const lyricNonNameRunes = "我你他她它们的了着过吗呢吧啊呀哦嗯不没很就都也还又再和跟与及说问答讲道是有在会要能可想觉得看听之乎者然后最先但而且或如果因为所以这那些"

var lyricInstrumentRoots = []string{
	"琴", "鼓", "号", "笛", "箫", "筝", "胡", "铃", "钹", "提琴", "吉他", "贝斯",
	"弦乐", "打击", "合成", "口琴", "竖琴", "单簧", "双簧", "萨克斯", "定音", "电子",
	"乐器", "乐团", "乐队", "编曲", "录音", "混音", "制作", "母带", "工程", "监制",
	"演出", "数字", "执行", "统筹", "企划", "发行", "出品", "作词", "作曲",
	"scratch", "beatbox", "mellotron", "sample", "programming",
}

var lyricExactCreditLabels = func() map[string]bool {
	m := map[string]bool{}
	for _, s := range []string{
		"词", "詞", "曲", "编", "編", "唱", "录", "錄", "混", "监", "監", "译", "譯",
		"词曲", "詞曲", "原唱", "演唱", "歌手", "出品", "发行", "發行", "策划", "策劃",
		"翻唱", "原曲", "歌名", "歌曲", "专辑", "專輯", "标题", "標題", "歌词", "歌詞",
		"op", "sp", "vocal", "lyrics", "music", "composer", "arranger", "producer",
	} {
		m[s] = true
	}
	return m
}()

func lyricPlausibleSpeakerName(label string) bool {
	rs := []rune(label)
	if len(rs) == 0 || len(rs) > lyricMaxLabelRunes {
		return false
	}
	if lyricExactCreditLabels[label] || lyricExactCreditLabels[strings.ToLower(label)] {
		return false
	}

	if creditLineRe.MatchString(label + "：") {
		return false
	}
	if strings.ContainsAny(label, lyricNonNameRunes) {
		return false
	}
	hasWord := false
	for _, r := range rs {
		if unicode.IsLetter(r) {
			hasWord = true
			break
		}
	}
	if !hasWord {
		return false
	}
	lowered := strings.ToLower(label)
	for _, root := range lyricInstrumentRoots {
		if strings.Contains(lowered, root) {
			return false
		}
	}
	return true
}

const (
	lyricMinDistinctUnknownSpeakers = 2
	lyricMinUnknownSpeakerHits      = 3
	lyricMinUnknownSpeakerRepeat    = 2
)

func lyricSpeakerLabels(lyrics string) map[string]bool {
	speakers := map[string]bool{}
	unknown := map[string]int{}
	for _, line := range splitLyricLines(lyrics) {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		label, _, ok := lyricSplitLabel(text)
		if !ok {
			continue
		}
		if lyricKnownSpeakerSet[label] {
			speakers[label] = true
		} else if lyricPlausibleSpeakerName(label) {

			unknown[label]++
		}
	}
	if len(unknown) < lyricMinDistinctUnknownSpeakers {
		return speakers
	}
	total, maxHits := 0, 0
	for _, n := range unknown {
		total += n
		if n > maxHits {
			maxHits = n
		}
	}
	if total < lyricMinUnknownSpeakerHits || maxHits < lyricMinUnknownSpeakerRepeat {
		return speakers
	}
	for label := range unknown {
		speakers[label] = true
	}
	return speakers
}

func splitLyricLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return strings.Split(s, "\n")
}

func isCreditLineWithSpeakers(text string, speakers map[string]bool) bool {
	if len(speakers) > 0 {
		if label, _, ok := lyricSplitLabel(text); ok && speakers[label] {
			return false
		}
	}
	return isCreditLine(text)
}
