package main

import (
	"context"
	"encoding/json"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

var (
	appleURLMu    sync.Mutex
	appleURLCache = map[string]appleMusicMatch{}
)

type appleMusicMatch struct {
	url, cover string

	title, album string

	durationSecs float64
}

func hiResArtwork(url string) string {
	if url == "" {
		return ""
	}
	return strings.Replace(url, "100x100bb", "1200x1200bb", 1)
}

func appleMusicMatchCachedOnly(artist, title, album string) appleMusicMatch {
	if title == "" {
		return appleMusicMatch{}
	}
	appleURLMu.Lock()
	defer appleURLMu.Unlock()
	return appleURLCache[artist+"|"+title+"|"+album]
}

func appleMusicMatchCached(ctx context.Context, artist, title, album string) appleMusicMatch {
	if title == "" {
		return appleMusicMatch{}
	}
	key := artist + "|" + title + "|" + album
	appleURLMu.Lock()
	if v, ok := appleURLCache[key]; ok {
		appleURLMu.Unlock()
		return v
	}
	appleURLMu.Unlock()

	m := resolveAppleMusicMatch(ctx, artist, title, album)
	if m.url != "" {
		appleURLMu.Lock()
		appleURLCache[key] = m
		appleURLMu.Unlock()
	}
	return m
}

func resolveAppleMusicMatch(ctx context.Context, artist, title, album string) appleMusicMatch {
	m, albumMatched := searchAppleMusicMatch(ctx, artist, title, album)
	if albumMatched {
		return m
	}

	if viaAlbum := resolveAppleMusicMatchViaAlbum(ctx, artist, title, album); viaAlbum.cover != "" || viaAlbum.url != "" {
		return viaAlbum
	}

	return m
}

func searchAppleMusicMatch(ctx context.Context, artist, title, album string) (appleMusicMatch, bool) {
	q := neturl.QueryEscape(artist + " " + title)
	var titleFallback appleMusicMatch
	bestScore := 0
	var best appleMusicMatch
	for _, country := range []string{"CN", "US"} {
		for _, r := range itunesSearch(ctx, q, country) {
			if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
				continue
			}
			if titleFallback.url == "" {
				titleFallback = appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000}
			}
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, best = sc, appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000}
			}
		}
	}
	if best.url != "" {
		return best, true
	}

	return titleFallback, false
}

func resolveAppleMusicMatchViaAlbum(ctx context.Context, artist, title, album string) appleMusicMatch {
	if album == "" {
		return appleMusicMatch{}
	}
	q := neturl.QueryEscape(artist + " " + album)
	for _, country := range []string{"CN", "US"} {
		bestID, bestScore := int64(0), 0
		var bestAlbumCover appleMusicMatch
		for _, r := range itunesSearch(ctx, q, country) {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
				bestAlbumCover = appleMusicMatch{cover: hiResArtwork(r.ArtworkURL100), album: r.CollectionName}
			}
		}
		if bestID == 0 {
			continue
		}
		for _, t := range itunesLookupTracks(ctx, bestID, country) {
			if t.TrackViewURL != "" && looseContains(t.TrackName, title) {
				return appleMusicMatch{url: t.TrackViewURL, cover: hiResArtwork(t.ArtworkURL100), title: t.TrackName, album: t.CollectionName, durationSecs: t.TrackTimeMillis / 1000}
			}
		}

		if bestScore >= 200 && bestAlbumCover.cover != "" {
			return bestAlbumCover
		}
	}
	return appleMusicMatch{}
}

var itunesHTTPClient = &http.Client{Timeout: 5 * time.Second}

func itunesLookupTracks(ctx context.Context, collectionID int64, country string) []itunesResult {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&entity=song&limit=50&country=%s", collectionID, country), nil)
	if err != nil {
		return nil
	}
	resp, err := doHTTPTracked(itunesHTTPClient, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType     string  `json:"wrapperType"`
			TrackName       string  `json:"trackName"`
			CollectionName  string  `json:"collectionName"`
			TrackViewURL    string  `json:"trackViewUrl"`
			ArtworkURL100   string  `json:"artworkUrl100"`
			ArtistName      string  `json:"artistName"`
			TrackTimeMillis float64 `json:"trackTimeMillis"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	tracks := make([]itunesResult, 0, len(out.Results))
	for _, r := range out.Results {
		if r.WrapperType != "track" {
			continue
		}

		tracks = append(tracks, itunesResult{
			TrackName: r.TrackName, CollectionName: r.CollectionName,
			TrackViewURL: r.TrackViewURL, ArtworkURL100: r.ArtworkURL100,
			ArtistName: r.ArtistName, TrackTimeMillis: r.TrackTimeMillis,
		})
	}
	return tracks
}

type itunesResult struct {
	TrackName      string `json:"trackName"`
	CollectionName string `json:"collectionName"`
	CollectionID   int64  `json:"collectionId"`
	TrackViewURL   string `json:"trackViewUrl"`
	ArtworkURL100  string `json:"artworkUrl100"`

	ArtistName string `json:"artistName"`

	TrackTimeMillis float64 `json:"trackTimeMillis"`

	ReleaseDate          string `json:"releaseDate"`
	CollectionArtistName string `json:"collectionArtistName"`
}

func itunesSearch(ctx context.Context, q, country string) []itunesResult {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://itunes.apple.com/search?media=music&entity=song&limit=25&country="+country+"&term="+q, nil)
	if err != nil {
		return nil
	}
	resp, err := doHTTPTracked(itunesHTTPClient, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []itunesResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	return out.Results
}
