package main

import (
	"fmt"
	"hash/crc32"
	"log"
	"os"
	"path/filepath"
	"strings"
)

var lyricsDir string

func splitEnrichKey(key string) (artist, title, album string) {
	parts := strings.SplitN(key, "|", 3)
	if len(parts) < 3 {
		return "", "", ""
	}
	return parts[0], parts[1], parts[2]
}

func lyricsFileHeader(artist, title, album, source string, manual bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[ar:%s]\n[ti:%s]\n[al:%s]\n", artist, title, album)
	if source != "" {
		fmt.Fprintf(&b, "[source:%s]\n", source)
	}
	if manual {
		b.WriteString("[manual:1]\n")
	}
	b.WriteString("\n")
	return b.String()
}

var lyricsFileSuffixes = [4]string{".lrc", ".tr.lrc", ".roma.lrc", ".yrc"}

func exportLyricsFiles() {
	if lyricsDir == "" {
		return
	}
	enrichSaveMu.Lock()
	defer enrichSaveMu.Unlock()
	enrichMu.Lock()
	// Hold the same sidecar lock through export so an old snapshot cannot restore
	// files the app just deleted, or overwrite its newly edited lyrics.
	if enrichPath != "" {
		lock, err := enrichCacheLock(enrichPath)
		if err != nil {
			enrichMu.Unlock()
			log.Printf("lyrics export lock: %v", err)
			return
		}
		defer unlockEnrichCache(lock)
		disk, err := readEnrichCacheDisk(enrichPath)
		if err != nil {
			enrichMu.Unlock()
			log.Printf("lyrics export cache: %v", err)
			return
		}
		baseline := enrichBaseline
		if !enrichBaselineReady || enrichBaselinePath != enrichPath {
			baseline = map[string]enrichEntry{}
		}
		merged, err := mergeEnrichCache(baseline, enrichCache, disk)
		if err != nil {
			enrichMu.Unlock()
			log.Printf("lyrics export merge: %v", err)
			return
		}
		noteExternalEnrichChanges(baseline, disk)
		enrichCache = merged
		enrichBaseline = cloneEnrichMap(disk)
		enrichBaselinePath, enrichBaselineReady = enrichPath, true
	}
	type entryJob struct {
		key                  string
		artist, title, album string
		source               string
		manual               bool
		variants             [4]string
	}
	jobs := make([]entryJob, 0, len(enrichCache))
	for key, e := range enrichCache {
		if e.Lyrics == "" {
			continue
		}
		artist, title, album := splitEnrichKey(key)
		if artist == "" || title == "" {

			continue
		}
		jobs = append(jobs, entryJob{
			key: key, artist: artist, title: title, album: album,
			source: e.LyricsSource, manual: e.ManualLyrics,
			variants: [4]string{e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC},
		})
	}
	enrichMu.Unlock()
	if len(jobs) == 0 {
		return
	}
	if err := os.MkdirAll(lyricsDir, 0o755); err != nil {
		return
	}

	byFold := make(map[string][]int, len(jobs))
	for i, j := range jobs {
		fold := strings.ToLower(sanitizeLyricsFilename(j.key))
		byFold[fold] = append(byFold[fold], i)
	}
	disambiguated := make(map[int]string, len(jobs))
	for _, idxs := range byFold {
		if len(idxs) < 2 {
			continue
		}
		for _, idx := range idxs {
			sum := crc32.ChecksumIEEE([]byte(jobs[idx].key))
			disambiguated[idx] = fmt.Sprintf("%s~%06x", sanitizeLyricsFilename(jobs[idx].key), sum&0xFFFFFF)
		}
	}

	for i, j := range jobs {
		base, ok := disambiguated[i]
		if !ok {
			base = sanitizeLyricsFilename(j.key)
		} else {

			plainBase := sanitizeLyricsFilename(j.key)
			for _, suffix := range lyricsFileSuffixes {
				_ = os.Remove(filepath.Join(lyricsDir, plainBase+suffix))
			}
		}
		header := lyricsFileHeader(j.artist, j.title, j.album, j.source, j.manual)
		for k, suffix := range lyricsFileSuffixes {
			path := filepath.Join(lyricsDir, base+suffix)
			content := j.variants[k]
			if content == "" {
				_ = os.Remove(path)
				continue
			}
			full := header + content
			if existing, err := os.ReadFile(path); err == nil && string(existing) == full {
				continue
			}
			if err := writeLyricsFileAtomic(path, []byte(full)); err != nil {
				log.Printf("lyrics export: write %s: %v", filepath.Base(path), err)
			}
		}
	}
}

func writeLyricsFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

func isLyricsTempFile(name string) bool {
	return strings.Contains(name, ".tmp.") && lyricsFileSuffixOf(name) == ""
}

func sanitizeLyricsFilename(key string) string {
	name := strings.ReplaceAll(key, "|", " - ")
	for _, c := range []string{"/", ":", "*", "?", "\"", "<", ">", "\\"} {
		name = strings.ReplaceAll(name, c, "_")
	}
	return strings.TrimSpace(name)
}
