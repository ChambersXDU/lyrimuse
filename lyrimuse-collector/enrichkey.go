package main

import (
	"fmt"
	"hash/crc32"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var enrichKeyVersionWords = []string{
	"remix", "mix", "live", "acoustic", "instrumental", "inst", "demo", "cover",
	"remaster", "version", "ver.", "edit", "extended", "radio", "karaoke",
	"reprise", "feat", "ft.", "featuring", "session", "mono", "stereo", "dub",
	"unplugged", "acappella", "a cappella",
	"interlude", "intro", "outro", "skit", "prelude", "overture",

	"慢板", "快板",
	"现场", "伴奏", "翻唱", "重制", "修复", "版", "纯音乐", "前奏", "间奏",
}

var enrichKeyTrailingBracket = regexp.MustCompile(`\s*[（(\[【]([^）)\]】]*)[）)\]】]\s*$`)

func enrichKey(artist, title, album string) string {
	return cleanMediaTag(artist) + "|" + normEnrichTitle(title) + "|" + cleanMediaTag(album)
}

func normEnrichTitle(title string) string {
	t := cleanMediaTag(title)
	for {
		m := enrichKeyTrailingBracket.FindStringSubmatchIndex(t)
		if m == nil {
			return t
		}
		inner := strings.ToLower(t[m[2]:m[3]])
		for _, w := range enrichKeyVersionWords {
			if strings.Contains(inner, w) {
				return t
			}
		}
		stripped := strings.TrimSpace(t[:m[0]])
		if stripped == "" {
			return t
		}
		t = stripped
	}
}

func enrichExportedFileNames(key string) []string {
	plain := sanitizeLyricsFilename(key)
	hashed := fmt.Sprintf("%s~%06x", plain, crc32.ChecksumIEEE([]byte(key))&0xFFFFFF)
	names := make([]string, 0, len(lyricsFileSuffixes)*2)
	for _, suffix := range lyricsFileSuffixes {
		names = append(names, plain+suffix, hashed+suffix)
	}
	return names
}

func betterEnrichEntry(a, b enrichEntry, aKey, bKey string) bool {
	if a.ManualLyrics != b.ManualLyrics {
		return a.ManualLyrics
	}
	if (a.Lyrics != "") != (b.Lyrics != "") {
		return a.Lyrics != ""
	}
	if a.LyricsScore != b.LyricsScore {
		return a.LyricsScore > b.LyricsScore
	}
	if (a.LyricsYRC != "") != (b.LyricsYRC != "") {
		return a.LyricsYRC != ""
	}
	if a.TS != b.TS {
		return a.TS > b.TS
	}
	return aKey < bKey
}

func mergePeripheralInto(winner, loser enrichEntry) enrichEntry {
	if winner.CoverURL == "" {
		winner.CoverURL, winner.CoverSource = loser.CoverURL, loser.CoverSource
	}
	if winner.AccentColor == "" {
		winner.AccentColor = loser.AccentColor
	}
	if winner.NeteaseURL == "" {
		winner.NeteaseURL = loser.NeteaseURL
	}
	if winner.AppleURL == "" {
		winner.AppleURL = loser.AppleURL
	}
	if winner.QQURL == "" {
		winner.QQURL = loser.QQURL
	}
	if winner.CanonicalArtist == "" {
		winner.CanonicalArtist = loser.CanonicalArtist
	}
	if winner.DurationSecs == 0 {
		winner.DurationSecs = loser.DurationSecs
	}
	return winner
}

func staleExportKeys(newKey, winnerKey string, olds []string) []string {
	out := make([]string, 0, len(olds))
	for _, k := range olds {
		if k == winnerKey && k == newKey {
			continue
		}
		out = append(out, k)
	}
	return out
}

func planEnrichKeyMigration(cache map[string]enrichEntry) map[string][]string {
	buckets := map[string][]string{}
	for k := range cache {
		artist, title, album := splitEnrichKey(k)
		if artist == "" && title == "" && album == "" {
			buckets[k] = append(buckets[k], k)
			continue
		}
		nk := enrichKey(artist, title, album)
		buckets[nk] = append(buckets[nk], k)
	}

	groups := map[string][]string{}
	for nk, ks := range buckets {
		merge, standalone := splitByDuration(cache, nk, ks)
		if len(merge) > 0 {
			groups[nk] = append(groups[nk], merge...)
		}
		for _, k := range standalone {
			groups[k] = append(groups[k], k)
		}
	}
	for _, ks := range groups {
		sort.Strings(ks)
	}
	return groups
}

func splitByDuration(cache map[string]enrichEntry, nk string, ks []string) (merge, standalone []string) {
	if len(ks) == 1 {
		return ks, nil
	}
	sorted := append([]string(nil), ks...)
	sort.Strings(sorted)
	anchor := sorted[0]
	for _, k := range sorted[1:] {
		if betterEnrichEntry(cache[k], cache[anchor], k, anchor) {
			anchor = k
		}
	}
	anchorDur := cache[anchor].DurationSecs
	for _, k := range sorted {
		if durationMismatch(anchorDur, cache[k].DurationSecs) {
			if k == nk {
				return nil, ks
			}
			standalone = append(standalone, k)
			continue
		}
		merge = append(merge, k)
	}
	return merge, standalone
}

const maxEnrichKeyDurationVariants = 8

func enrichKeyDurationVariant(key string, n int) string {
	artist, title, album := splitEnrichKey(key)
	return artist + "|" + fmt.Sprintf("%s~dur%d", title, n) + "|" + album
}

func resolveEnrichKeyForDuration(cache map[string]enrichEntry, key string, durationSecs float64) (string, enrichEntry, bool) {
	if e, ok := cache[key]; !ok || !durationMismatch(e.DurationSecs, durationSecs) {
		return key, e, ok
	}
	for n := 2; n <= maxEnrichKeyDurationVariants; n++ {
		vk := enrichKeyDurationVariant(key, n)
		e, ok := cache[vk]
		if !ok || !durationMismatch(e.DurationSecs, durationSecs) {
			return vk, e, ok
		}
	}
	return key, cache[key], true
}

func migrateEnrichKeys() {

	if applyEnrichKeyMigration() {
		saveEnrichCache()
	}
}

func applyEnrichKeyMigration() bool {
	enrichMu.Lock()
	defer enrichMu.Unlock()

	groups := planEnrichKeyMigration(enrichCache)
	needsWork := false
	for nk, olds := range groups {
		if len(olds) > 1 || olds[0] != nk {
			needsWork = true
			break
		}
	}
	if !needsWork {
		return false
	}

	if enrichPath != "" {
		backup := enrichPath + ".pre-keynorm.bak"
		if _, err := os.Stat(backup); os.IsNotExist(err) {
			if data, err := os.ReadFile(enrichPath); err == nil {
				if err := os.WriteFile(backup, data, 0o644); err != nil {
					log.Printf("enrich key migration: backup failed (%v), aborting", err)
					return false
				}
				log.Printf("enrich key migration: backed up %d entries to %s", len(enrichCache), filepath.Base(backup))
			}
		}
	}

	merged := make(map[string]enrichEntry, len(groups))
	stale := map[string]bool{}
	renamed, mergedAway := 0, 0
	for nk, olds := range groups {
		winnerKey := olds[0]
		for _, k := range olds[1:] {
			if betterEnrichEntry(enrichCache[k], enrichCache[winnerKey], k, winnerKey) {
				winnerKey = k
			}
		}
		e := enrichCache[winnerKey]
		for _, k := range olds {
			if k == winnerKey {
				continue
			}
			e = mergePeripheralInto(e, enrichCache[k])
			mergedAway++

			log.Printf("enrich key migration: dropping %q (source=%s score=%d) in favour of %q",
				k, enrichCache[k].LyricsSource, enrichCache[k].LyricsScore, winnerKey)
		}
		merged[nk] = e
		for _, k := range staleExportKeys(nk, winnerKey, olds) {
			stale[k] = true
			if k == winnerKey {
				renamed++
			}
		}
		if len(olds) > 1 {
			log.Printf("enrich key migration: %q kept %s (source=%s score=%d manual=%v)",
				nk, winnerKey, e.LyricsSource, e.LyricsScore, e.ManualLyrics)
		}
	}

	removedFiles := 0
	if lyricsDir != "" {
		for k := range stale {
			for _, name := range enrichExportedFileNames(k) {
				if err := os.Remove(filepath.Join(lyricsDir, name)); err == nil {
					removedFiles++
				}
			}
		}
	}

	log.Printf("enrich key migration: %d entries -> %d (%d renamed, %d merged away, %d stale files removed)",
		len(merged)+mergedAway, len(merged), renamed, mergedAway, removedFiles)
	enrichCache = merged
	enrichDirty = true
	return true
}
