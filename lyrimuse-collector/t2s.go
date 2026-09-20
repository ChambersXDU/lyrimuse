package main

import (
	"bufio"
	"bytes"
	"embed"
	"strings"
)

//go:embed dictionary/TSCharacters.txt dictionary/TSPhrases.txt
var t2sDictFS embed.FS

var (
	t2sCharMap      map[string]string
	t2sPhraseMap    map[string]string
	t2sMaxPhraseLen int
)

func init() {
	t2sCharMap = loadT2SDict("dictionary/TSCharacters.txt")
	t2sPhraseMap = loadT2SDict("dictionary/TSPhrases.txt")
	for k := range t2sPhraseMap {
		if n := len([]rune(k)); n > t2sMaxPhraseLen {
			t2sMaxPhraseLen = n
		}
	}
}

func loadT2SDict(path string) map[string]string {
	m := map[string]string{}
	data, err := t2sDictFS.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		items := strings.SplitN(line, "\t", 2)
		if len(items) < 2 {
			continue
		}
		fields := strings.Fields(items[1])
		if len(fields) == 0 {
			continue
		}
		m[items[0]] = fields[0]
	}
	return m
}

func toSimplifiedT2S(s string) string {
	runes := []rune(s)
	var b strings.Builder
	b.Grow(len(s))
	i := 0
	for i < len(runes) {
		matched := false
		maxLen := t2sMaxPhraseLen
		if remain := len(runes) - i; remain < maxLen {
			maxLen = remain
		}
		for l := maxLen; l >= 2; l-- {
			candidate := string(runes[i : i+l])
			if repl, ok := t2sPhraseMap[candidate]; ok {
				b.WriteString(repl)
				i += l
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		r := runes[i]
		if repl, ok := t2sCharMap[string(r)]; ok {
			b.WriteString(repl)
		} else if std, ok := hanVariantMap[r]; ok {

			b.WriteRune(std)
		} else {
			b.WriteRune(r)
		}
		i++
	}
	return b.String()
}
