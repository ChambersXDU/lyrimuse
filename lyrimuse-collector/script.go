package main

import "unicode"

type lyricScript int

const (
	scriptNone lyricScript = iota
	scriptLatin
	scriptHan
	scriptKana
	scriptHangul
	scriptCyrillic
	scriptArabic
	scriptThai
)

var scriptOrder = []lyricScript{
	scriptKana, scriptHangul, scriptHan, scriptCyrillic, scriptArabic, scriptThai, scriptLatin,
}

func dominantScript(s string) lyricScript {
	counts := map[lyricScript]int{}
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r):
			counts[scriptKana]++
		case unicode.Is(unicode.Han, r):
			counts[scriptHan]++
		case unicode.Is(unicode.Hangul, r):
			counts[scriptHangul]++
		case unicode.Is(unicode.Cyrillic, r):
			counts[scriptCyrillic]++
		case unicode.Is(unicode.Arabic, r):
			counts[scriptArabic]++
		case unicode.Is(unicode.Thai, r):
			counts[scriptThai]++
		case unicode.IsLetter(r):
			counts[scriptLatin]++
		}
	}
	if counts[scriptKana] > 0 {
		return scriptKana
	}
	best, bestCount := scriptNone, 0
	for _, script := range scriptOrder {
		if counts[script] > bestCount {
			best, bestCount = script, counts[script]
		}
	}
	return best
}
