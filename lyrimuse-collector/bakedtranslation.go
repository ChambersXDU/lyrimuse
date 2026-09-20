package main

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

var yrcWordTimingRe = regexp.MustCompile(`\(\d+,\d+(?:,\d+)?\)`)

const (
	bakedTranslationMinLines   = 8
	bakedTranslationMinRatio   = 0.7
	bakedTranslationMaxRatio   = 1.3
	bakedTranslationMinPaired  = 0.8
	bakedTranslationYRCSlackMs = 80
)

type bakedLineClass int

const (
	bakedLineSkip    bakedLineClass = iota
	bakedLineForeign
	bakedLineHan
	bakedLineMixed
)

type bakedLine struct {
	raw     string
	stamps  string
	text    string
	class   bakedLineClass
	startMs int
	jk      bool
}

func classifyBakedLine(line string) bakedLine {
	bl := bakedLine{raw: line, startMs: -1}
	m := lrcTimestampCaptureRe.FindAllStringSubmatchIndex(line, -1)
	if len(m) == 0 {
		bl.class = bakedLineSkip
		return bl
	}

	end := 0
	for _, mm := range m {
		if strings.TrimSpace(line[end:mm[0]]) != "" {
			break
		}
		end = mm[1]
	}
	if end == 0 {
		bl.class = bakedLineSkip
		return bl
	}
	bl.stamps = line[:end]
	bl.text = strings.TrimSpace(line[end:])
	if first := lrcTimestampCaptureRe.FindStringSubmatch(bl.stamps); first != nil {
		mm, _ := strconv.Atoi(first[1])
		ss, _ := strconv.Atoi(first[2])
		frac, _ := strconv.Atoi(first[3])
		switch len(first[3]) {
		case 1:
			frac *= 100
		case 2:
			frac *= 10
		}
		bl.startMs = mm*60000 + ss*1000 + frac
	}
	if bl.text == "" || isLRCMetaTagLine(bl.text) || isCreditLine(bl.text) {
		bl.class = bakedLineSkip
		return bl
	}
	han, latin, jk := 0, 0, 0
	for _, r := range bl.text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case r < 0x80 && unicode.IsLetter(r):
			latin++
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r):
			jk++
		}
	}
	switch {
	case jk > 0:
		bl.class, bl.jk = bakedLineForeign, true
	case latin >= 2 && han == 0:
		bl.class = bakedLineForeign
	case han >= 2 && latin == 0:
		bl.class = bakedLineHan
	default:
		bl.class = bakedLineMixed
	}
	return bl
}

func splitBakedTranslation(lyrics, yrc string, foreignSong bool) (cleanLRC, trLRC, cleanYRC string, n int) {
	if lyrics == "" {
		return lyrics, "", yrc, 0
	}
	lines := splitLyricLines(lyrics)
	parsed := make([]bakedLine, len(lines))
	foreign, han, jkForeign, paired := 0, 0, 0, 0
	prevClass := bakedLineSkip
	for i, l := range lines {
		parsed[i] = classifyBakedLine(l)
		c := parsed[i].class
		switch c {
		case bakedLineForeign:
			foreign++
			if parsed[i].jk {
				jkForeign++
			}
		case bakedLineHan:
			han++
			if prevClass == bakedLineForeign {
				paired++
			}
		}
		if c != bakedLineSkip {
			prevClass = c
		}
	}
	if foreign < bakedTranslationMinLines || han < bakedTranslationMinLines {
		return lyrics, "", yrc, 0
	}
	ratio := float64(han) / float64(foreign)
	if ratio < bakedTranslationMinRatio || ratio > bakedTranslationMaxRatio {
		return lyrics, "", yrc, 0
	}
	if float64(paired) < bakedTranslationMinPaired*float64(han) {
		return lyrics, "", yrc, 0
	}
	if !foreignSong && 2*jkForeign < foreign {
		return lyrics, "", yrc, 0
	}

	var clean, tr []string
	removedMs := map[int]bool{}
	removedText := map[string]bool{}
	lastStamps := ""
	trText := map[string]string{}
	var trOrder []string
	for _, bl := range parsed {
		switch bl.class {
		case bakedLineHan:
			n++
			if bl.startMs >= 0 {
				removedMs[bl.startMs] = true
			}
			removedText[normLoose(bl.text)] = true
			stamps := lastStamps
			if stamps == "" {
				stamps = bl.stamps
			}
			if prev, ok := trText[stamps]; ok {
				trText[stamps] = prev + " " + bl.text
			} else {
				trText[stamps] = bl.text
				trOrder = append(trOrder, stamps)
			}
			continue
		case bakedLineForeign:
			lastStamps = bl.stamps
		}
		clean = append(clean, bl.raw)
	}
	for _, stamps := range trOrder {
		tr = append(tr, stamps+trText[stamps])
	}
	cleanLRC = strings.Join(clean, "\n")
	trLRC = strings.Join(tr, "\n")
	cleanYRC = stripBakedYRCLines(yrc, removedMs, removedText)
	return cleanLRC, trLRC, cleanYRC, n
}

func stripBakedYRCLines(yrc string, removedMs map[int]bool, removedText map[string]bool) string {
	if yrc == "" || (len(removedMs) == 0 && len(removedText) == 0) {
		return yrc
	}
	lines := strings.Split(yrc, "\n")
	kept := make([]string, 0, len(lines))
	for _, l := range lines {
		m := yrcLineTimeRegex.FindStringSubmatch(l)
		if m == nil {
			kept = append(kept, l)
			continue
		}
		start, _ := strconv.Atoi(m[1])
		drop := false
		for ms := range removedMs {
			if d := ms - start; d <= bakedTranslationYRCSlackMs && d >= -bakedTranslationYRCSlackMs {
				drop = true
				break
			}
		}
		if !drop {
			text := normLoose(yrcWordTimingRe.ReplaceAllString(l[len(m[0]):], ""))
			if text != "" && removedText[text] {
				drop = true
			}
		}
		if !drop {
			kept = append(kept, l)
		}
	}
	return strings.Join(kept, "\n")
}

func adoptBakedTranslation(lyr, tr, yrc string, foreignSong, acceptTr bool) (string, string, string, int) {
	clean, bakedTr, cleanYRC, n := splitBakedTranslation(lyr, yrc, foreignSong)
	if n == 0 {
		return lyr, tr, yrc, 0
	}
	if acceptTr && tr == "" {
		tr = bakedTr
	}
	return clean, tr, cleanYRC, n
}
