package main

import (
	"bufio"
	"bytes"
	"embed"
	"strings"
	"unicode"
)

//go:embed dictionary/JyutpingChars.txt
var jyutpingDictFS embed.FS

var jyutpingCharMap map[rune]string

//go:embed dictionary/JyutpingCollisionOverrides.txt
var jyutpingCollisionOverrideDictFS embed.FS

var jyutpingCollisionOverrideMap map[rune]string

//go:embed dictionary/JyutpingWords.txt
var jyutpingWordDictFS embed.FS

var jyutpingWordMap map[string]string

var jyutpingMaxWordRunes int

func init() {
	jyutpingCharMap = loadJyutpingDict(jyutpingDictFS, "dictionary/JyutpingChars.txt")
	jyutpingCollisionOverrideMap = loadJyutpingDict(jyutpingCollisionOverrideDictFS, "dictionary/JyutpingCollisionOverrides.txt")
	jyutpingWordMap = loadJyutpingWordDict("dictionary/JyutpingWords.txt")
	for w := range jyutpingWordMap {
		if n := len([]rune(w)); n > jyutpingMaxWordRunes {
			jyutpingMaxWordRunes = n
		}
	}
}

func loadJyutpingDict(fs embed.FS, path string) map[rune]string {
	m := map[rune]string{}
	data, err := fs.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || parts[1] == "" {
			continue
		}
		r := []rune(parts[0])
		if len(r) != 1 {
			continue
		}
		m[r[0]] = parts[1]
	}
	return m
}

func loadJyutpingWordDict(path string) map[string]string {
	m := map[string]string{}
	data, err := jyutpingWordDictFS.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || parts[1] == "" {
			continue
		}
		if len([]rune(parts[0])) < 2 {
			continue
		}
		if !isAllHan(parts[0]) {
			continue
		}
		m[parts[0]] = parts[1]
	}
	return m
}

func isAllHan(s string) bool {
	for _, r := range s {
		if !unicode.Is(unicode.Han, r) {
			return false
		}
	}
	return true
}

func jyutpingReading(r rune) (string, bool) {

	if jp, ok := jyutpingCollisionOverrideMap[r]; ok {
		return jp, true
	}
	if jp, ok := jyutpingCharMap[r]; ok {
		return jp, true
	}
	if trad, ok := s2tCharMap[string(r)]; ok {
		tr := []rune(trad)
		if len(tr) == 1 {
			if jp, ok := jyutpingCharMap[tr[0]]; ok {
				return jp, true
			}
		}
	}
	return "", false
}

func jyutpingWordReading(word string) (string, bool) {
	if jp, ok := jyutpingWordMap[word]; ok {
		return jp, true
	}
	runes := []rune(word)
	converted := make([]rune, len(runes))
	changed := false
	for i, r := range runes {
		if trad, ok := s2tCharMap[string(r)]; ok {
			tr := []rune(trad)
			if len(tr) == 1 {
				converted[i] = tr[0]
				if tr[0] != r {
					changed = true
				}
				continue
			}
		}
		converted[i] = r
	}
	if !changed {
		return "", false
	}
	jp, ok := jyutpingWordMap[string(converted)]
	return jp, ok
}

func toJyutpingLine(text string) string {
	runes := []rune(text)
	var b strings.Builder

	var lastRune rune
	lastWasSyllable := false

	sep := func() {
		if lastRune != 0 && !unicode.IsSpace(lastRune) {
			b.WriteByte(' ')
			lastRune = ' '
		}
	}
	emit := func(jp string) {
		if jp == "" {
			return
		}
		sep()
		b.WriteString(jp)
		jpRunes := []rune(jp)
		lastRune = jpRunes[len(jpRunes)-1]
		lastWasSyllable = true
	}
	for i := 0; i < len(runes); {
		matched := false
		maxLen := jyutpingMaxWordRunes
		if remaining := len(runes) - i; maxLen > remaining {
			maxLen = remaining
		}
		for l := maxLen; l >= 2; l-- {
			if jp, ok := jyutpingWordReading(string(runes[i : i+l])); ok {
				emit(jp)
				i += l
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		r := runes[i]
		if jp, ok := jyutpingReading(r); ok {
			emit(jp)
			i++
			continue
		}
		if unicode.IsSpace(r) {
			b.WriteRune(r)
			lastRune = r
			lastWasSyllable = false
			i++
			continue
		}

		if lastWasSyllable {
			sep()
		}
		b.WriteRune(r)
		lastRune = r
		lastWasSyllable = false
		i++
	}
	return b.String()
}

func jyutpingLRC(lyrics string) string {
	lines := parseLRCLines(lyrics)
	if len(lines) == 0 {
		return ""
	}
	texts := make([]string, len(lines))
	for i, l := range lines {
		texts[i] = toJyutpingLine(l.text)
	}
	return assembleTranslationLRC(lines, texts, len(lines)).lrc
}
