package main

import (
	"html"
	"log"
	"regexp"
	"strings"
)

var lyricEntityRe = regexp.MustCompile(`&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});`)

func decodeLyricEntities(s string) string {
	if !strings.Contains(s, "&") {
		return s
	}
	return lyricEntityRe.ReplaceAllStringFunc(s, func(m string) string {
		u := html.UnescapeString(m)
		if u == m {
			return m
		}
		if u == "\u00a0" {
			return " "
		}
		for _, r := range u {
			if r < 0x20 || r == 0x7f {
				return m
			}
		}
		return u
	})
}

func decodeLyricSourceResultEntities(r lyricSourceResult) lyricSourceResult {
	r.lyr = decodeLyricEntities(r.lyr)
	r.yrc = decodeLyricEntities(r.yrc)
	r.tr = decodeLyricEntities(r.tr)
	r.roma = decodeLyricEntities(r.roma)
	r.ne.Lyrics = decodeLyricEntities(r.ne.Lyrics)
	r.ne.Trans = decodeLyricEntities(r.ne.Trans)
	r.ne.Roma = decodeLyricEntities(r.ne.Roma)
	r.ne.YRC = decodeLyricEntities(r.ne.YRC)
	r.amll.lrc = decodeLyricEntities(r.amll.lrc)
	r.amll.yrc = decodeLyricEntities(r.amll.yrc)
	r.amll.tr = decodeLyricEntities(r.amll.tr)
	return r
}

func decodeLyricSourceEntities(raw map[string]lyricSourceResult) map[string]lyricSourceResult {
	out := make(map[string]lyricSourceResult, len(raw))
	for k, r := range raw {
		out[k] = decodeLyricSourceResultEntities(r)
	}
	return out
}

func migrateLyricEntities() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		lyrics := decodeLyricEntities(e.Lyrics)
		tr := decodeLyricEntities(e.LyricsTr)
		roma := decodeLyricEntities(e.LyricsRoma)
		yrc := decodeLyricEntities(e.LyricsYRC)
		plain := decodeLyricEntities(e.PlainLyrics)
		if lyrics == e.Lyrics && tr == e.LyricsTr && roma == e.LyricsRoma && yrc == e.LyricsYRC && plain == e.PlainLyrics {
			continue
		}
		if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics) {
			e.ManualPickSHA = manualPickFingerprint(lyrics)
		}
		e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics = lyrics, tr, roma, yrc, plain
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {

		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("lyric entity migration: decoded HTML entities in %d entries", fixed)
		saveEnrichCache()
	}
}
