package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (

	appleCatalogMaxPlausibleID = 1_000_000_000_000

	appleCatalogMaxMisses = 3

	appleCatalogDurationLogThreshold = 0.5
)

type appleCatalogTrack struct {
	TrackName string `json:"track_name"`

	ArtistName string `json:"artist_name"`

	AlbumArtist  string  `json:"album_artist,omitempty"`
	AlbumName    string  `json:"album_name"`
	AlbumID      int64   `json:"album_id"`
	DurationSecs float64 `json:"duration_secs"`

	TrackNumber int `json:"track_number,omitempty"`
}

var (
	appleCatalogMu       sync.Mutex
	appleCatalogCache    = map[string]appleCatalogTrack{}
	appleCatalogPath     string
	appleCatalogDirty    bool
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses   = map[int64]int{}

	appleCatalogByTrack = map[string]appleCatalogTrack{}
)

func appleCatalogIndexKey(title, album string) string {
	return normLoose(title) + "|" + normLoose(album)
}

func appleCatalogAlbumIDFor(title, album string) (int64, bool) {
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	want := appleCatalogIndexKey(title, album)
	if t, ok := appleCatalogByTrack[want]; ok && t.AlbumID > 0 {
		return t.AlbumID, true
	}
	for _, c := range appleCatalogCache {
		if c.AlbumID > 0 && appleCatalogIndexKey(c.TrackName, c.AlbumName) == want {
			return c.AlbumID, true
		}
	}
	return 0, false
}

func loadAppleCatalogCache(path string) {
	appleCatalogMu.Lock()
	appleCatalogPath = path
	appleCatalogMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]appleCatalogTrack
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		appleCatalogMu.Lock()
		appleCatalogCache = m
		appleCatalogMu.Unlock()
		log.Printf("cache: loaded %d Apple catalog tracks from %s", len(m), path)
	}
}

func saveAppleCatalogCache() {
	appleCatalogMu.Lock()
	if !appleCatalogDirty || appleCatalogPath == "" {
		appleCatalogMu.Unlock()
		return
	}
	data, err := json.Marshal(appleCatalogCache)
	path := appleCatalogPath
	if err != nil {
		appleCatalogMu.Unlock()
		return
	}
	appleCatalogDirty = false
	appleCatalogMu.Unlock()

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		appleCatalogMu.Lock()
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		log.Printf("save apple catalog cache: %v", err)
		return
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		appleCatalogMu.Lock()
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		log.Printf("save apple catalog cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		appleCatalogMu.Lock()
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		log.Printf("save apple catalog cache: %v", err)
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		appleCatalogMu.Lock()
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		log.Printf("save apple catalog cache: %v", err)
	}
}

func appleCatalogPlausibleID(trackID int64) bool {
	return trackID > 0 && trackID < appleCatalogMaxPlausibleID
}

var appleCatalogHTTPClient = &http.Client{Timeout: 5 * time.Second}

func appleCatalogLookup(trackID int64) (appleCatalogTrack, bool) {
	u := fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&country=cn", trackID)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return appleCatalogTrack{}, false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(appleCatalogHTTPClient, req)
	if err != nil {
		return appleCatalogTrack{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return appleCatalogTrack{}, false
	}
	var r struct {
		Results []struct {
			WrapperType          string  `json:"wrapperType"`
			TrackName            string  `json:"trackName"`
			ArtistName           string  `json:"artistName"`
			CollectionArtistName string  `json:"collectionArtistName"`
			CollectionName       string  `json:"collectionName"`
			CollectionID         int64   `json:"collectionId"`
			TrackNumber          int     `json:"trackNumber"`
			TrackTimeMillis      float64 `json:"trackTimeMillis"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return appleCatalogTrack{}, false
	}
	for _, it := range r.Results {

		if it.WrapperType != "track" || it.TrackName == "" {
			continue
		}
		t := appleCatalogTrack{
			TrackName:    cleanMediaTag(it.TrackName),
			ArtistName:   cleanMediaTag(it.ArtistName),
			AlbumArtist:  cleanMediaTag(it.CollectionArtistName),
			AlbumName:    cleanMediaTag(it.CollectionName),
			AlbumID:      it.CollectionID,
			TrackNumber:  it.TrackNumber,
			DurationSecs: it.TrackTimeMillis / 1000,
		}
		appleCatalogMu.Lock()
		appleCatalogCache[fmt.Sprint(trackID)] = t
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		saveAppleCatalogCache()
		return t, true
	}
	return appleCatalogTrack{}, false
}

func appleCatalogTrackCachedOnly(trackID int64) (appleCatalogTrack, bool) {
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	t, ok := appleCatalogCache[fmt.Sprint(trackID)]
	return t, ok
}

func prefetchAppleCatalogTrack(trackID int64) {
	if !appleCatalogPlausibleID(trackID) {
		return
	}
	appleCatalogMu.Lock()
	if appleCatalogInflight[trackID] || appleCatalogMisses[trackID] >= appleCatalogMaxMisses {
		appleCatalogMu.Unlock()
		return
	}
	if _, ok := appleCatalogCache[fmt.Sprint(trackID)]; ok {
		appleCatalogMu.Unlock()
		return
	}
	appleCatalogInflight[trackID] = true
	appleCatalogMu.Unlock()

	go func() {
		_, ok := appleCatalogLookup(trackID)
		appleCatalogMu.Lock()
		delete(appleCatalogInflight, trackID)
		if !ok {
			appleCatalogMisses[trackID]++
		}
		appleCatalogMu.Unlock()
	}()
}

func appleCatalogAnchor(bundleID string, trackID int64, localTrackNumber int, localTitle, localAlbum string) (appleCatalogTrack, bool) {
	if bundleID != appleMusicBundleID || localTitle == "" || !appleCatalogPlausibleID(trackID) {
		return appleCatalogTrack{}, false
	}
	t, ok := appleCatalogTrackCachedOnly(trackID)
	if !ok {
		prefetchAppleCatalogTrack(trackID)
		return appleCatalogTrack{}, false
	}

	if normLoose(t.TrackName) == "" || normLoose(t.TrackName) != normLoose(localTitle) {
		return appleCatalogTrack{}, false
	}
	if localAlbum != "" && albumScore(t.AlbumName, localAlbum) < 100 {
		return appleCatalogTrack{}, false
	}

	if localTrackNumber > 0 && t.TrackNumber > 0 && localTrackNumber != t.TrackNumber {
		return appleCatalogTrack{}, false
	}
	appleCatalogMu.Lock()
	appleCatalogByTrack[appleCatalogIndexKey(localTitle, localAlbum)] = t
	appleCatalogMu.Unlock()
	return t, true
}

func appleCatalogSearchIdentities(artist, title, album string) []string {
	appleCatalogMu.Lock()
	t, ok := appleCatalogByTrack[appleCatalogIndexKey(title, album)]
	if !ok {

		want := appleCatalogIndexKey(title, album)
		for _, c := range appleCatalogCache {
			if appleCatalogIndexKey(c.TrackName, c.AlbumName) == want {
				t, ok = c, true
				break
			}
		}
	}
	appleCatalogMu.Unlock()
	if !ok {
		return nil
	}
	var out []string
	seen := map[string]bool{normLoose(artist): true}
	for _, cand := range []string{t.AlbumArtist, t.ArtistName} {
		n := normLoose(cand)
		if cand == "" || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, cand)
	}
	return out
}

var (
	appleStorefrontArtistMu    sync.Mutex
	appleStorefrontArtistCache = map[string][]string{}
	appleStorefrontArtistPath  string
	appleStorefrontArtistDirty bool
)

const appleStorefrontArtistCacheVersion = 2

type appleStorefrontArtistFile struct {
	Version int                 `json:"version"`
	Entries map[string][]string `json:"entries"`
}

func loadAppleStorefrontArtistCache(path string) {
	appleStorefrontArtistPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f appleStorefrontArtistFile
	if err := json.Unmarshal(data, &f); err == nil && f.Version == appleStorefrontArtistCacheVersion && f.Entries != nil {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = f.Entries
		appleStorefrontArtistMu.Unlock()
		log.Printf("cache: loaded %d Apple storefront artist entries from %s", len(f.Entries), path)
		return
	}
	var legacy map[string][]string
	if err := json.Unmarshal(data, &legacy); err == nil && legacy != nil {
		log.Printf("cache: discarding %d unverified v1 Apple storefront artist entries from %s (re-derived on demand with per-track verification)", len(legacy), path)
	}
}

func saveAppleStorefrontArtistCache() {
	appleStorefrontArtistMu.Lock()
	if !appleStorefrontArtistDirty || appleStorefrontArtistPath == "" {
		appleStorefrontArtistMu.Unlock()
		return
	}
	keep := make(map[string][]string, len(appleStorefrontArtistCache))
	for k, v := range appleStorefrontArtistCache {
		if len(v) > 0 {
			keep[k] = v
		}
	}
	data, err := json.Marshal(appleStorefrontArtistFile{Version: appleStorefrontArtistCacheVersion, Entries: keep})
	appleStorefrontArtistDirty = false
	path := appleStorefrontArtistPath
	appleStorefrontArtistMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("save apple storefront artist cache: %v", err)
	}
}

var (
	appleStorefrontTitleMu    sync.Mutex
	appleStorefrontTitleCache = map[string]string{}
	appleStorefrontTitlePath  string
	appleStorefrontTitleDirty bool
)

const appleStorefrontTitleCacheVersion = 1

type appleStorefrontTitleFile struct {
	Version int               `json:"version"`
	Entries map[string]string `json:"entries"`
}

func loadAppleStorefrontTitleCache(path string) {
	appleStorefrontTitlePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f appleStorefrontTitleFile
	if err := json.Unmarshal(data, &f); err == nil && f.Version == appleStorefrontTitleCacheVersion && f.Entries != nil {
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache = f.Entries
		appleStorefrontTitleMu.Unlock()
		log.Printf("cache: loaded %d Apple storefront title entries from %s", len(f.Entries), path)
	}
}

func saveAppleStorefrontTitleCache() {
	appleStorefrontTitleMu.Lock()
	if !appleStorefrontTitleDirty || appleStorefrontTitlePath == "" {
		appleStorefrontTitleMu.Unlock()
		return
	}
	entries := make(map[string]string, len(appleStorefrontTitleCache))
	for k, v := range appleStorefrontTitleCache {
		entries[k] = v
	}
	data, err := json.Marshal(appleStorefrontTitleFile{Version: appleStorefrontTitleCacheVersion, Entries: entries})
	appleStorefrontTitleDirty = false
	path := appleStorefrontTitlePath
	appleStorefrontTitleMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("save apple storefront title cache: %v", err)
	}
}

func appleStorefrontArtistIdentities(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) []string {
	names, _ := appleStorefrontIdentitiesAndTitle(ctx, artist, title, album, durationSecs, lyricSamples)
	return names
}

func appleStorefrontCanonicalTitle(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) string {
	_, canonical := appleStorefrontIdentitiesAndTitle(ctx, artist, title, album, durationSecs, lyricSamples)
	return canonical
}

func appleStorefrontIdentitiesAndTitle(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) (names []string, canonicalTitle string) {
	if album == "" {
		return nil, ""
	}

	key := normLoose(artist) + "|" + normLoose(album)
	titleKey := key + "|" + normLoose(title)
	appleStorefrontArtistMu.Lock()
	cachedNames, namesOK := appleStorefrontArtistCache[key]
	appleStorefrontArtistMu.Unlock()
	appleStorefrontTitleMu.Lock()
	cachedTitle, titleOK := appleStorefrontTitleCache[titleKey]
	appleStorefrontTitleMu.Unlock()

	if namesOK && titleOK {
		return cachedNames, cachedTitle
	}

	q := neturl.QueryEscape(artist + " " + album)
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	probed := false
	for _, country := range appleStorefrontsFor(append([]string{artist, title, album}, lyricSamples...)...) {
		bestID, bestScore := int64(0), 0
		for _, r := range itunesSearch(ctx, q, country) {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
			}
		}
		if bestID == 0 {
			continue
		}
		var hit *itunesResult
		tracks := itunesLookupTracks(ctx, bestID, country)
		probed = true
		for i := range tracks {
			if appleStorefrontTrackMatches(title, durationSecs, tracks[i]) {
				hit = &tracks[i]
				break
			}
		}
		if hit == nil {
			log.Printf("lyrics: storefront %s: album %q matched %q by name only, none of its %d tracks is %q (%.0fs) — treated as a different album", country, album, artist, len(tracks), title, durationSecs)
			continue
		}

		if canonicalTitle == "" && hit.TrackName != "" && normLoose(hit.TrackName) != normLoose(title) {
			canonicalTitle = hit.TrackName
		}
		n := normLoose(hit.ArtistName)
		if hit.ArtistName == "" || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, hit.ArtistName)
	}

	appleStorefrontArtistMu.Lock()
	appleStorefrontArtistCache[key] = out

	if len(out) > 0 {
		appleStorefrontArtistDirty = true
	}
	appleStorefrontArtistMu.Unlock()
	saveAppleStorefrontArtistCache()
	if probed {

		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache[titleKey] = canonicalTitle
		appleStorefrontTitleDirty = true
		appleStorefrontTitleMu.Unlock()
		saveAppleStorefrontTitleCache()
	}
	return out, canonicalTitle
}

func appleStorefrontTrackMatches(localTitle string, durationSecs float64, t itunesResult) bool {
	want := normLoose(localTitle)
	if want == "" {
		return false
	}
	sameTitle := normLoose(t.TrackName) == want
	if durationSecs <= 0 {
		return sameTitle
	}
	if t.TrackTimeMillis <= 0 || math.Abs(t.TrackTimeMillis/1000-durationSecs) > appleTitleSearchDurationTolerance(durationSecs) {
		return false
	}
	return sameTitle || artistScriptDiffers(localTitle, t.TrackName)
}

func appleStorefrontsFor(samples ...string) []string {
	out := []string{"CN", "US"}
	seen := map[string]bool{"CN": true, "US": true}
	add := func(c string) {
		if !seen[c] && len(out) < 4 {
			seen[c] = true
			out = append(out, c)
		}
	}
	for _, sample := range samples {
		switch dominantScript(sample) {
		case scriptKana:
			add("JP")
		case scriptHangul:
			add("KR")
		case scriptCyrillic:
			add("RU")
		case scriptThai:
			add("TH")
		case scriptHan:
			if toSimplified(sample) != sample {
				add("TW")
			}
		}
	}
	return out
}

func lyricSamplesForStorefront(results []scoredLyricCandidateResult) []string {
	var out []string
	for _, r := range results {
		if r.Lyrics == "" {
			continue
		}
		rs := []rune(r.Lyrics)
		if len(rs) > 300 {
			rs = rs[:300]
		}
		out = append(out, string(rs))
		if len(out) >= 3 {
			break
		}
	}
	return out
}

const (
	appleTitleSearchMaxIdentities = 2

	appleTitleSearchMinDurationSecs = 75
)

func appleTitleSearchDurationTolerance(durationSecs float64) float64 {
	return math.Max(4, durationSecs*0.03)
}

var (
	appleTitleSearchIdentityMu    sync.Mutex
	appleTitleSearchIdentityCache = map[string][]string{}
)

func appleTitleSearchIdentities(ctx context.Context, artist, title string, durationSecs float64) []string {
	if strings.TrimSpace(title) == "" {
		return nil
	}
	key := normLoose(artist) + "|" + normLoose(title) + "|" + fmt.Sprintf("%.0f", durationSecs)
	appleTitleSearchIdentityMu.Lock()
	if v, ok := appleTitleSearchIdentityCache[key]; ok {
		appleTitleSearchIdentityMu.Unlock()
		return v
	}
	appleTitleSearchIdentityMu.Unlock()

	var out []string
	for _, q := range []string{strings.TrimSpace(artist + " " + title), title} {
		var results []itunesResult
		for _, country := range []string{"CN", "US"} {
			results = append(results, itunesSearch(ctx, neturl.QueryEscape(q), country)...)
		}
		if out = pickAppleTitleSearchIdentities(results, artist, title, durationSecs); len(out) > 0 {
			break
		}
	}
	if len(out) > 0 {
		log.Printf("lyrics: apple title-search identities for %q - %q (%.1fs): %v", artist, title, durationSecs, out)
	}
	appleTitleSearchIdentityMu.Lock()
	appleTitleSearchIdentityCache[key] = out
	appleTitleSearchIdentityMu.Unlock()
	return out
}

func pickAppleTitleSearchIdentities(results []itunesResult, artist, title string, durationSecs float64) []string {
	want := normLoose(title)
	if want == "" {
		return nil
	}
	if durationSecs > 0 && durationSecs < appleTitleSearchMinDurationSecs {
		return nil
	}
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	for _, r := range results {
		if normLoose(r.TrackName) != want {
			continue
		}
		if durationSecs > 0 {
			if r.TrackTimeMillis <= 0 {
				continue
			}
			if math.Abs(r.TrackTimeMillis/1000-durationSecs) > appleTitleSearchDurationTolerance(durationSecs) {
				continue
			}
		} else if len(out) >= 1 {

			break
		}
		n := normLoose(r.ArtistName)
		if r.ArtistName == "" || n == "" || seen[n] {
			continue
		}
		if !artistScriptDiffers(artist, r.ArtistName) {
			continue
		}
		seen[n] = true
		out = append(out, r.ArtistName)
		if len(out) >= appleTitleSearchMaxIdentities {
			break
		}
	}
	return out
}

func artistScriptDiffers(local, candidate string) bool {
	if strings.TrimSpace(local) == "" {
		return true
	}
	return containsCJKScript(local) != containsCJKScript(candidate)
}

func containsCJKScript(s string) bool {
	for _, r := range s {
		if isCJKScriptRune(r) {
			return true
		}
	}
	return false
}

func dedupeArtistIdentities(groups ...[]string) []string {
	seen := map[string]bool{}
	var out []string
	for _, g := range groups {
		for _, name := range g {
			n := normLoose(name)
			if name == "" || n == "" || seen[n] {
				continue
			}
			seen[n] = true
			out = append(out, name)
		}
	}
	return out
}
