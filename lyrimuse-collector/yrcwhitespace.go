package main

import (
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
)

var yrcWordTokenRe = regexp.MustCompile(`\((\d+),(\d+),(\d+)\)`)

func yrcMergeWhitespaceTokens(yrc string) (string, bool) {
	if yrc == "" || !strings.Contains(yrc, ")") {
		return yrc, false
	}
	changed := false
	lines := strings.Split(yrc, "\n")
	for li, line := range lines {
		if !strings.HasPrefix(line, "[") || !strings.Contains(line, "(") {
			continue
		}
		locs := yrcWordTokenRe.FindAllStringSubmatchIndex(line, -1)
		if len(locs) == 0 {
			continue
		}
		type tok struct {
			start, dur int64
			flag       string
			text       string
		}
		head := line[:locs[0][0]]
		toks := make([]tok, 0, len(locs))
		lineChanged := false
		prefix := ""
		for i, m := range locs {
			start, _ := strconv.ParseInt(line[m[2]:m[3]], 10, 64)
			dur, _ := strconv.ParseInt(line[m[4]:m[5]], 10, 64)
			flag := line[m[6]:m[7]]
			textEnd := len(line)
			if i+1 < len(locs) {
				textEnd = locs[i+1][0]
			}
			text := line[m[1]:textEnd]
			if text != "" && strings.TrimSpace(text) == "" {
				lineChanged = true
				if n := len(toks); n > 0 {
					toks[n-1].text += text
					if end := start + dur; end > toks[n-1].start+toks[n-1].dur {
						toks[n-1].dur = end - toks[n-1].start
					}
				} else {
					prefix += text
				}
				continue
			}
			toks = append(toks, tok{start, dur, flag, prefix + text})
			prefix = ""
		}
		if !lineChanged {
			continue
		}
		var b strings.Builder
		b.WriteString(head)
		for _, t := range toks {
			fmt.Fprintf(&b, "(%d,%d,%s)%s", t.start, t.dur, t.flag, t.text)
		}
		lines[li] = b.String()
		changed = true
	}
	if !changed {
		return yrc, false
	}
	return strings.Join(lines, "\n"), true
}

func migrateYRCWhitespaceTokens() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		merged, ok := yrcMergeWhitespaceTokens(e.LyricsYRC)
		if !ok {
			continue
		}
		e.LyricsYRC = merged
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {

		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("yrc whitespace-token migration: merged space tokens in %d entries", fixed)
		saveEnrichCache()
	}
}
