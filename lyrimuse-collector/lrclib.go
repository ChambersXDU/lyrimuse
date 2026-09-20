package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg"
	_ "image/png"
	"math"
	"net/http"
	neturl "net/url"
	"sync"
	"time"
)

type lrclibResult struct {
	lyrics, title, artist, album string

	durationSecs float64
	instrumental bool

	plainOnly bool
}

var (
	lrclibMu    sync.Mutex
	lrclibCache = map[string]lrclibResult{}
)

func lrclibLyric(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	if title == "" {
		return lrclibResult{}
	}

	key := artist + "|" + title + "|" + album
	lrclibMu.Lock()
	if v, ok := lrclibCache[key]; ok {
		lrclibMu.Unlock()
		return v
	}
	lrclibMu.Unlock()

	r := resolveLRCLIBLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" || r.instrumental {
		lrclibMu.Lock()
		lrclibCache[key] = r
		lrclibMu.Unlock()
	}
	return r
}

func resolveLRCLIBLyric(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	if r := lrclibGet(ctx, artist, title, album, 8*time.Second); r.lyrics != "" || r.instrumental {
		return r
	}
	if album != "" {
		if r := lrclibGet(ctx, artist, title, "", 5*time.Second); r.lyrics != "" || r.instrumental {
			return r
		}
	}
	return lrclibSearch(ctx, artist, title, album, durationSecs, 5*time.Second)
}

func lrclibRequest(ctx context.Context, url string, timeout time.Duration, out any) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}

	req.Header.Set("User-Agent", clientName+"/"+clientVersion+" (+https://github.com/Yudaotor/desktop-lyrics-suite)")
	resp, err := doHTTPTracked(lyricHTTPClient(timeout), req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	return json.NewDecoder(resp.Body).Decode(out) == nil
}

func lrclibGet(ctx context.Context, artist, title, album string, timeout time.Duration) lrclibResult {
	u := "https://lrclib.net/api/get?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	if album != "" {
		u += "&album_name=" + neturl.QueryEscape(album)
	}
	var out lrclibSearchItem
	if !lrclibRequest(ctx, u, timeout, &out) {
		return lrclibResult{}
	}
	if out.Instrumental {
		return lrclibResult{instrumental: true}
	}
	if isTimedLRC(out.SyncedLyrics) {
		return lrclibResult{lyrics: out.SyncedLyrics, durationSecs: out.Duration, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
	}

	if out.PlainLyrics != "" {
		return lrclibResult{lyrics: out.PlainLyrics, plainOnly: true, durationSecs: out.Duration, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
	}
	return lrclibResult{}
}

type lrclibSearchItem struct {
	TrackName    string  `json:"trackName"`
	ArtistName   string  `json:"artistName"`
	AlbumName    string  `json:"albumName"`
	Duration     float64 `json:"duration"`
	Instrumental bool    `json:"instrumental"`
	SyncedLyrics string  `json:"syncedLyrics"`

	PlainLyrics string `json:"plainLyrics"`
}

func lrclibSearchItems(ctx context.Context, artist, title string, timeout time.Duration) []lrclibSearchItem {
	u := "https://lrclib.net/api/search?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	var items []lrclibSearchItem
	if !lrclibRequest(ctx, u, timeout, &items) {
		return nil
	}
	return items
}

func lrclibSearch(ctx context.Context, artist, title, album string, durationSecs float64, timeout time.Duration) lrclibResult {

	queries := searchTitleVariants(title)
	lists := make([][]lrclibSearchItem, len(queries))
	var wg sync.WaitGroup
	for i, q := range queries {
		wg.Add(1)
		go func(idx int, query string) {
			defer wg.Done()
			lists[idx] = lrclibSearchItems(ctx, artist, query, timeout)
		}(i, q)
	}
	wg.Wait()
	var items []lrclibSearchItem
	for _, l := range lists {
		items = append(items, l...)
	}

	if lyricSearchItemsTap != nil {
		lyricSearchItemsTap("lrclib", artist, title, album, durationSecs, items)
	}
	best, plainOnly := pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, false)
	if best == nil {
		best, plainOnly = pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, true)
	}
	if best == nil {
		return lrclibResult{}
	}
	lyrics := best.SyncedLyrics
	if plainOnly {
		lyrics = best.PlainLyrics
	}
	return lrclibResult{lyrics: lyrics, plainOnly: plainOnly, durationSecs: best.Duration, title: best.TrackName, artist: best.ArtistName, album: best.AlbumName}
}

const lrclibSearchDurationTolerance = 0.25

func pickLRCLIBSearchResult(items []lrclibSearchItem, artist, title, album string, durationSecs float64) *lrclibSearchItem {
	best, _ := pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, false)
	return best
}

func pickLRCLIBSearchResultDetailed(items []lrclibSearchItem, artist, title, album string, durationSecs float64, allowPlainOnly bool) (best *lrclibSearchItem, plainOnly bool) {
	bestDiff := -1.0
	for i := range items {
		it := &items[i]
		timed := isTimedLRC(it.SyncedLyrics)
		if !timed && !(allowPlainOnly && it.PlainLyrics != "") {
			continue
		}
		if !lyricTitleAccepted(it.TrackName, title) ||
			!lyricSourceArtistMatches(it.ArtistName, artist) {
			continue
		}

		if versionTagsMismatch(title, album, it.TrackName, it.AlbumName) &&
			!sameRecordingDespiteVersionTags(title, album, durationSecs, it.TrackName, it.AlbumName, it.Duration) {
			continue
		}
		if durationSecs <= 0 {
			if best == nil {
				best, plainOnly = it, !timed
			}
			continue
		}
		if it.Duration <= 0 {
			continue
		}
		diff := math.Abs(it.Duration-durationSecs) / durationSecs
		if diff > lrclibSearchDurationTolerance {
			continue
		}
		if bestDiff < 0 || diff < bestDiff {
			best, bestDiff, plainOnly = it, diff, !timed
		}
	}
	return best, plainOnly
}
