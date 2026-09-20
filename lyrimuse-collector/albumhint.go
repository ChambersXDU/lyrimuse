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
	"sort"
	"strings"
	"sync"
	"time"
)

const appleAlbumHintMaxMisses = 2

type albumHintCandidate struct {
	Artist string `json:"artist"`

	TitleArtist string `json:"title_artist,omitempty"`

	CollectionArtist string `json:"collection_artist,omitempty"`
	Album            string `json:"album"`
	CollectionID     int64  `json:"collection_id,omitempty"`

	TrackRelease string `json:"track_release,omitempty"`

	AlbumRelease string `json:"album_release,omitempty"`

	Order int `json:"order"`
}

var (
	appleAlbumHintMu       sync.Mutex
	appleAlbumHintCache    = map[string][]albumHintCandidate{}
	appleAlbumHintPath     string
	appleAlbumHintDirty    bool
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintWaiters  = map[string]chan struct{}{}
	appleAlbumHintMisses   = map[string]int{}
	appleAlbumHintLogged   = map[string]string{}

	albumHintLookupHTTPClient = &http.Client{Timeout: 6 * time.Second}
)

func appleAlbumHintKey(artist, title string, durationSecs float64) string {
	return strings.TrimSpace(artist) + "|" + strings.TrimSpace(title) + "|" + fmt.Sprintf("%.0f", durationSecs)
}

func appleAlbumHintEligible(artist, title string, durationSecs float64) bool {
	return strings.TrimSpace(artist) != "" && strings.TrimSpace(title) != "" &&
		durationSecs >= appleTitleSearchMinDurationSecs
}

func loadAppleAlbumHintCache(path string) {
	appleAlbumHintMu.Lock()
	appleAlbumHintPath = path
	appleAlbumHintMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string][]albumHintCandidate
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		appleAlbumHintMu.Lock()
		appleAlbumHintCache = m
		appleAlbumHintMu.Unlock()
		log.Printf("cache: loaded %d Apple album-hint candidate sets from %s", len(m), path)
	}
}

func saveAppleAlbumHintCache() {
	appleAlbumHintMu.Lock()
	if !appleAlbumHintDirty || appleAlbumHintPath == "" {
		appleAlbumHintMu.Unlock()
		return
	}
	data, err := json.Marshal(appleAlbumHintCache)
	path := appleAlbumHintPath
	if err != nil {
		appleAlbumHintMu.Unlock()
		return
	}
	appleAlbumHintDirty = false
	appleAlbumHintMu.Unlock()

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
	}
}

func appleAlbumHint(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)
	appleAlbumHintMu.Lock()
	if cands, ok := appleAlbumHintCache[key]; ok {
		appleAlbumHintMu.Unlock()
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}
	if appleAlbumHintInflight[key] || appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
		appleAlbumHintMu.Unlock()
		return ""
	}
	appleAlbumHintInflight[key] = true
	waitCh := make(chan struct{})
	appleAlbumHintWaiters[key] = waitCh
	appleAlbumHintMu.Unlock()
	go func() {
		cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
		storeAppleAlbumHintResult(key, cands, concluded)
	}()
	return ""
}

const appleAlbumHintSyncWait = 8 * time.Second

func appleAlbumHintSync(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)

	appleAlbumHintMu.Lock()
	if cands, ok := appleAlbumHintCache[key]; ok {
		appleAlbumHintMu.Unlock()
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}

	if !appleAlbumHintInflight[key] {
		if appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
			appleAlbumHintMu.Unlock()
			return ""
		}
		appleAlbumHintInflight[key] = true
		waitCh := make(chan struct{})
		appleAlbumHintWaiters[key] = waitCh
		appleAlbumHintMu.Unlock()

		cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
		storeAppleAlbumHintResult(key, cands, concluded)
		if len(cands) == 0 {
			return ""
		}
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}

	waitCh, ok := appleAlbumHintWaiters[key]
	if !ok {
		waitCh = make(chan struct{})
		appleAlbumHintWaiters[key] = waitCh
	}
	appleAlbumHintMu.Unlock()

	timer := time.NewTimer(appleAlbumHintSyncWait)
	defer timer.Stop()

	select {
	case <-waitCh:
		appleAlbumHintMu.Lock()
		cands := appleAlbumHintCache[key]
		appleAlbumHintMu.Unlock()
		if len(cands) == 0 {
			return ""
		}
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	case <-ctx.Done():
		return ""
	case <-timer.C:
		return ""
	}
}

func storeAppleAlbumHintResult(key string, cands []albumHintCandidate, concluded bool) {
	appleAlbumHintMu.Lock()
	delete(appleAlbumHintInflight, key)
	if ch, ok := appleAlbumHintWaiters[key]; ok {
		delete(appleAlbumHintWaiters, key)
		close(ch)
	}
	if len(cands) == 0 {
		if concluded {
			appleAlbumHintMisses[key]++
		}
	} else {
		appleAlbumHintCache[key] = cands
		appleAlbumHintDirty = true
	}
	appleAlbumHintMu.Unlock()
	if len(cands) > 0 {
		saveAppleAlbumHintCache()
	}
}

func pickAppleAlbumHintLogged(key string, cands []albumHintCandidate, artist, title string, durationSecs float64, resolvedArtists []string) string {
	album := pickAppleAlbumHint(cands, artist, resolvedArtists)
	if album == "" {
		return ""
	}
	appleAlbumHintMu.Lock()
	logged := appleAlbumHintLogged[key] == album
	if !logged {
		appleAlbumHintLogged[key] = album
	}
	appleAlbumHintMu.Unlock()
	if !logged {
		log.Printf("album hint: %q - %q (%.0fs) -> %q (apple catalog, %d candidates)", artist, title, durationSecs, album, len(cands))
	}
	return album
}

func coverAlbumForTrack(ctx context.Context, artist, title, album string, durationSecs float64) string {
	if album != "" {
		return album
	}
	return appleAlbumHint(ctx, artist, title, durationSecs, lyricResolvedArtists(artist, title, album))
}

func coverAlbumCorroboration(artist, title, album, canonical string, picked *scoredLyricCandidateResult) []string {
	out := lyricResolvedArtists(artist, title, album)
	if strings.TrimSpace(canonical) != "" {
		out = append(out, canonical)
	}
	if picked != nil && strings.TrimSpace(picked.Artist) != "" {
		out = append(out, picked.Artist)
	}
	return out
}

func coverNeedsHintCheck(e enrichEntry, album, hint string) bool {
	if album != "" || hint == "" || e.CoverURL == "" || e.CoverAlbum == "" {
		return false
	}
	if e.CoverSource != "netease" && e.CoverSource != "apple" {
		return false
	}
	return albumScore(e.CoverAlbum, hint) == 0
}

func fetchAppleAlbumHintCandidates(ctx context.Context, artist, title string, durationSecs float64) []albumHintCandidate {
	var results []itunesResult
	for _, q := range []string{strings.TrimSpace(artist + " " + title), title} {
		for _, country := range []string{"CN", "US"} {
			results = append(results, itunesSearch(ctx, neturl.QueryEscape(q), country)...)
		}
	}
	cands := albumHintCandidatesFromResults(results, title, durationSecs)
	if len(cands) == 0 {

		if titleArtist, song, ok := albumHintTitleSplit(title); ok {
			var alt []itunesResult
			q := neturl.QueryEscape(titleArtist + " " + song)
			for _, country := range []string{"CN", "US"} {
				alt = append(alt, itunesSearch(ctx, q, country)...)
			}
			cands = albumHintCandidatesFromTitleSplit(alt, titleArtist, song, durationSecs)
		}
	}
	if len(cands) == 0 {
		return nil
	}
	var ids []int64
	seen := map[int64]bool{}
	for _, c := range cands {
		if c.CollectionID != 0 && !seen[c.CollectionID] {
			seen[c.CollectionID] = true
			ids = append(ids, c.CollectionID)
		}
	}
	releases := itunesLookupCollectionReleaseDates(ctx, ids, "US")
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	return cands
}

func fetchAppleAlbumHintCandidatesTracked(ctx context.Context, artist, title string, durationSecs float64) (cands []albumHintCandidate, concluded bool) {
	end := beginNetworkRound()
	cands = fetchAppleAlbumHintCandidates(ctx, artist, title, durationSecs)
	attempts, failures := end()
	return cands, appleAlbumHintQueryConcluded(len(cands), attempts, failures)
}

func appleAlbumHintQueryConcluded(n int, attempts, failures int32) bool {
	return n > 0 || lyricsRoundConfirmsNoResult(attempts, failures)
}

func albumHintCandidatesFromResults(results []itunesResult, title string, durationSecs float64) []albumHintCandidate {
	want := normLoose(title)
	if want == "" || durationSecs < appleTitleSearchMinDurationSecs {
		return nil
	}
	tolerance := appleTitleSearchDurationTolerance(durationSecs)
	var out []albumHintCandidate
	seen := map[string]bool{}
	for _, r := range results {
		if normLoose(r.TrackName) != want {
			continue
		}
		if r.TrackTimeMillis <= 0 || math.Abs(r.TrackTimeMillis/1000-durationSecs) > tolerance {
			continue
		}
		album, who := cleanMediaTag(r.CollectionName), cleanMediaTag(r.ArtistName)
		if album == "" || who == "" {
			continue
		}
		dk := normLoose(who) + "|" + normLoose(album)
		if seen[dk] {
			continue
		}
		seen[dk] = true
		out = append(out, albumHintCandidate{
			Artist: who, CollectionArtist: cleanMediaTag(r.CollectionArtistName), Album: album,
			CollectionID: r.CollectionID, TrackRelease: r.ReleaseDate, Order: len(out),
		})
	}
	return out
}

func albumHintTitleSplit(title string) (artist, song string, ok bool) {
	clean := normEnrichTitle(title)
	best, sepLen := -1, 0
	for _, sep := range []string{" - ", " – ", " — "} {
		if i := strings.Index(clean, sep); i >= 0 && (best < 0 || i < best) {
			best, sepLen = i, len(sep)
		}
	}
	if best < 0 {
		return "", "", false
	}
	artist, song = strings.TrimSpace(clean[:best]), strings.TrimSpace(clean[best+sepLen:])
	if normLoose(artist) == "" || normLoose(song) == "" {
		return "", "", false
	}
	return artist, song, true
}

func albumHintCandidatesFromTitleSplit(results []itunesResult, titleArtist, song string, durationSecs float64) []albumHintCandidate {
	var out []albumHintCandidate
	for _, c := range albumHintCandidatesFromResults(results, song, durationSecs) {
		if albumHintArtistTier(titleArtist, c.Artist, nil) != 0 {
			continue
		}
		c.TitleArtist = titleArtist
		out = append(out, c)
	}
	return out
}

func itunesLookupCollectionReleaseDates(ctx context.Context, ids []int64, country string) map[int64]string {
	if len(ids) == 0 {
		return nil
	}
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, fmt.Sprint(id))
	}
	u := "https://itunes.apple.com/lookup?country=" + country + "&id=" + strings.Join(parts, ",")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(albumHintLookupHTTPClient, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType  string `json:"wrapperType"`
			CollectionID int64  `json:"collectionId"`
			ReleaseDate  string `json:"releaseDate"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	m := map[int64]string{}
	for _, r := range out.Results {
		if r.WrapperType == "collection" && r.CollectionID != 0 && r.ReleaseDate != "" {
			m[r.CollectionID] = r.ReleaseDate
		}
	}
	return m
}

func pickAppleAlbumHint(cands []albumHintCandidate, artist string, resolvedArtists []string) string {
	resolved := map[string]bool{}
	for _, a := range resolvedArtists {
		if n := normLoose(a); n != "" {
			resolved[n] = true
		}
	}
	type scored struct {
		c       albumHintCandidate
		rank    int
		release string
	}
	var accepted []scored
	for _, c := range cands {
		tier := albumHintArtistTier(artist, c.Artist, resolved)
		if tier < 0 && c.TitleArtist != "" && albumHintArtistTier(c.TitleArtist, c.Artist, nil) == 0 {
			tier = 0
		}
		if tier < 0 {
			continue
		}
		rank := tier * 10
		if c.CollectionArtist != "" && normLoose(c.CollectionArtist) != normLoose(c.Artist) {
			rank += 4
		}
		if albumHintIsSingleOrEP(c.Album) {
			rank += 2
		}
		if albumHintHasEditionQualifier(c.Album) {
			rank++
		}
		release := c.AlbumRelease
		if release == "" {
			release = c.TrackRelease
		}
		accepted = append(accepted, scored{c: c, rank: rank, release: release})
	}
	if len(accepted) == 0 {
		return ""
	}
	sort.SliceStable(accepted, func(a, b int) bool {
		if accepted[a].rank != accepted[b].rank {
			return accepted[a].rank < accepted[b].rank
		}
		ra, rb := accepted[a].release, accepted[b].release
		if ra != rb {
			if ra == "" {
				return false
			}
			if rb == "" {
				return true
			}
			return ra < rb
		}
		return accepted[a].c.Order < accepted[b].c.Order
	})
	return accepted[0].c.Album
}

func albumHintArtistTier(local, candidate string, resolved map[string]bool) int {
	l, c := normLoose(local), normLoose(candidate)
	if l == "" || c == "" {
		return -1
	}
	if l == c {
		return 0
	}
	lp, cp := artistCreditParts(local), artistCreditParts(candidate)
	if len(lp) > 0 && len(cp) > 0 && (creditPartsSubset(lp, cp) || creditPartsSubset(cp, lp)) {
		return 0
	}
	if resolved[c] {
		return 1
	}
	return -1
}

func creditPartsSubset(a, b []string) bool {
	set := map[string]bool{}
	for _, p := range b {
		set[normLoose(p)] = true
	}
	for _, p := range a {
		if !set[normLoose(p)] {
			return false
		}
	}
	return true
}

func albumHintIsSingleOrEP(album string) bool {
	a := strings.ToLower(strings.TrimSpace(album))
	return strings.HasSuffix(a, " - single") || strings.HasSuffix(a, " - ep")
}

func albumHintHasEditionQualifier(album string) bool {
	a := strings.ToLower(album)
	for _, m := range []string{"deluxe", "edition", "remaster", "expanded", "anniversary", "bonus", "reissue", "豪华", "纪念版", "复刻"} {
		if strings.Contains(a, m) {
			return true
		}
	}
	return false
}

func lyricResolvedArtists(artist, title, album string) []string {
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		if alt, found := canonicalEnrichKey(key); found {
			e, ok = enrichCache[alt]
		}
	}
	enrichMu.Unlock()
	if !ok {
		return nil
	}
	var out []string
	if e.CanonicalArtist != "" {
		out = append(out, e.CanonicalArtist)
	}
	if d := e.LyricsDecisionApplied; d != nil && d.Winner != "" {
		for _, c := range d.Candidates {
			if c.Source == d.Winner && strings.TrimSpace(c.Artist) != "" {
				out = append(out, c.Artist)
				break
			}
		}
	}
	return out
}
