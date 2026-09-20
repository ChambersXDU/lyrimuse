package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"strings"
)

func manualPickFingerprint(lyrics string) string {
	canonical := manualPickCanonicalLyrics(lyrics)
	if canonical == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:])[:12]
}

func manualPickCanonicalLyrics(lyrics string) string {
	var b strings.Builder
	for _, raw := range strings.Split(lyrics, "\n") {
		line := strings.TrimSpace(raw)

		for strings.HasPrefix(line, "[") {
			end := strings.Index(line, "]")
			if end < 0 {
				break
			}
			line = strings.TrimSpace(line[end+1:])
		}
		if line == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(line)
	}
	return b.String()
}

func migrateManualPickMarks() {
	enrichMu.Lock()
	marked, cleared := 0, 0
	for k, e := range enrichCache {
		if e.LyricsSourceChoice == "" {
			continue
		}
		choice := e.LyricsSourceChoice
		e.LyricsSourceChoice = ""
		cleared++

		if sha := manualPickFingerprint(e.Lyrics); sha != "" &&
			e.ManualPickSHA == "" && !e.ManualLyrics && e.LyricsSource == choice {
			e.ManualPickSHA = sha
			marked++
		}
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("manual pick migration: converted %d/%d legacy lyrics_source_choice entries into manual pick marks",
			marked, cleared)
		saveEnrichCache()
	}
}
