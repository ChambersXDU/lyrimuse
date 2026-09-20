package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	lyricsHeaderArtistRe = regexp.MustCompile(`^\[ar:(.*)\]$`)
	lyricsHeaderTitleRe  = regexp.MustCompile(`^\[ti:(.*)\]$`)
	lyricsHeaderAlbumRe  = regexp.MustCompile(`^\[al:(.*)\]$`)
	lyricsHeaderSourceRe = regexp.MustCompile(`^\[source:(.*)\]$`)
	lyricsHeaderManualRe = regexp.MustCompile(`^\[manual:1\]$`)
)

type parsedLyricsFile struct {
	artist, title, album string
	source               string
	manual               bool
	body                 string
	ok                   bool
}

func parseLyricsFile(path string) parsedLyricsFile {
	var p parsedLyricsFile
	data, err := os.ReadFile(path)
	if err != nil {
		return p
	}
	lines := strings.Split(string(data), "\n")
	get := func(i int) (string, bool) {
		if i < 0 || i >= len(lines) {
			return "", false
		}
		return strings.TrimRight(lines[i], "\r"), true
	}

	i := 0
	line, ok := get(i)
	m := lyricsHeaderArtistRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.artist = m[1]
	i++

	line, ok = get(i)
	m = lyricsHeaderTitleRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.title = m[1]
	i++

	line, ok = get(i)
	m = lyricsHeaderAlbumRe.FindStringSubmatch(line)
	if !ok || m == nil {
		return p
	}
	p.album = m[1]
	i++

	if line, ok = get(i); ok {
		if m := lyricsHeaderSourceRe.FindStringSubmatch(line); m != nil {
			p.source = m[1]
			i++
		}
	}
	if line, ok = get(i); ok {
		if lyricsHeaderManualRe.MatchString(line) {
			p.manual = true
			i++
		}
	}

	if line, ok = get(i); !ok || line != "" {
		return p
	}
	i++

	p.body = strings.Join(lines[i:], "\n")

	p.ok = p.artist != "" && p.title != ""
	return p
}

func readVariantBody(path string) string {
	if path == "" {
		return ""
	}
	return parseLyricsFile(path).body
}

func lyricsFileSuffixOf(name string) string {
	var suffix string
	for _, s := range lyricsFileSuffixes {
		if strings.HasSuffix(name, s) && len(s) > len(suffix) {
			suffix = s
		}
	}
	return suffix
}

func importLyricsFromFiles() {
	if lyricsDir == "" {
		return
	}
	entries, err := os.ReadDir(lyricsDir)
	if err != nil {
		return
	}

	type group struct{ files map[string]string }
	groups := make(map[string]*group)
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()

		if isLyricsTempFile(name) {
			_ = os.Remove(filepath.Join(lyricsDir, name))
			continue
		}
		suffix := lyricsFileSuffixOf(name)
		if suffix == "" {
			continue
		}
		base := strings.TrimSuffix(name, suffix)
		g, ok := groups[base]
		if !ok {
			g = &group{files: map[string]string{}}
			groups[base] = g
		}
		g.files[suffix] = filepath.Join(lyricsDir, name)
	}

	enrichMu.Lock()
	for _, g := range groups {

		var parsed parsedLyricsFile
		for _, suffix := range lyricsFileSuffixes {
			path, ok := g.files[suffix]
			if !ok {
				continue
			}
			if p := parseLyricsFile(path); p.ok {
				parsed = p
				break
			}
		}
		if !parsed.ok {
			continue
		}

		key := enrichKey(parsed.artist, parsed.title, parsed.album)

		e := enrichCache[key]
		changed := false
		if path, ok := g.files[".lrc"]; ok {
			if v := readVariantBody(path); e.Lyrics != v {
				e.Lyrics, changed = v, true
			}
		}
		if path, ok := g.files[".tr.lrc"]; ok {
			if v := readVariantBody(path); e.LyricsTr != v {
				e.LyricsTr, changed = v, true

				e.LyricsTrLang = ""
			}
		}
		if path, ok := g.files[".roma.lrc"]; ok {
			if v := readVariantBody(path); e.LyricsRoma != v {
				e.LyricsRoma, changed = v, true
			}
		}
		if path, ok := g.files[".yrc"]; ok {
			if v := readVariantBody(path); e.LyricsYRC != v {
				e.LyricsYRC, changed = v, true
			}
		}
		if e.LyricsSource != parsed.source {
			e.LyricsSource, changed = parsed.source, true
		}
		if e.ManualLyrics != parsed.manual {
			e.ManualLyrics, changed = parsed.manual, true
		}
		if changed {
			enrichCache[key] = e
			enrichDirty = true
		}
	}
	enrichMu.Unlock()
	saveEnrichCache()
}
