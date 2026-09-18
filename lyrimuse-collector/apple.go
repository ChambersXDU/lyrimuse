// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
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

// appleMusicMatch stores metadata matched against the iTunes / Apple Music catalog.
// Provides link URLs for client navigation, official artwork for cover fallbacks,
// canonical titles/albums for independent verification, and track duration for catalog validation.
type appleMusicMatch struct {
	url, cover string
	// title and album as cataloged in iTunes, used for independent corroboration.
	title, album string
	// durationSecs is the catalog track duration in seconds.
	durationSecs float64
}

// hiResArtwork replaces the default 100x100 artwork URL dimension segment with 1200x1200.
// Apple mzstatic CDNs support direct dimension replacement in URLs without separate API requests.
// 1200x1200 provides crisp rendering across Retina displays and floating lyrics window cards.
func hiResArtwork(url string) string {
	if url == "" {
		return ""
	}
	return strings.Replace(url, "100x100bb", "1200x1200bb", 1)
}

// appleMusicMatchCached retrieves or queries Apple Music match metadata cached by artist|title|album.
// appleMusicMatchCachedOnly accesses the in-memory cache exclusively without network requests.
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

// resolveAppleMusicMatch returns the Apple Music song match, disambiguated by
// album: the same song appears on many albums (originals, compilations, "This
// Is It"), so results[0] often points at the wrong album. Prefer title+album
// match, then title match, then first result. China store first (user
// preference), US fallback.
func resolveAppleMusicMatch(ctx context.Context, artist, title, album string) appleMusicMatch {
	m, albumMatched := searchAppleMusicMatch(ctx, artist, title, album)
	if albumMatched {
		return m
	}
	// When full-text search yields no album-verified match (only titleFallback), attempt precise
	// album-level lookup via resolveAppleMusicMatchViaAlbum. Album-level lookup resolves the original
	// studio release even if compilation appearances dominate full-text ranking.
	if viaAlbum := resolveAppleMusicMatchViaAlbum(ctx, artist, title, album); viaAlbum.cover != "" || viaAlbum.url != "" {
		return viaAlbum
	}
	// 按专辑定位也没查到任何东西——titleFallback 好歹是张图,好过没有(哪怕专辑可能不对)。
	return m
}

// searchAppleMusicMatch 在 iTunes 全文搜索里找这首歌。第二个返回值标出这条结果是不是
// **有专辑证据**支撑的(albumScore>0)——调用方(resolveAppleMusicMatch)靠它判断要不要
// 再去按专辑名精确定位试一次:titleFallback 那种"完全没有专辑证据、只是标题对上的第一条"
// 太弱,专辑名一旦跟本地对不上就可能是完全不相关的另一个发行版,不该被当成终局结果。
func searchAppleMusicMatch(ctx context.Context, artist, title, album string) (appleMusicMatch, bool) {
	q := neturl.QueryEscape(artist + " " + title)
	var titleFallback appleMusicMatch
	bestScore := 0
	var best appleMusicMatch
	for _, country := range []string{"CN", "US"} {
		for _, r := range itunesSearch(ctx, q, country) {
			if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
				continue // skip unrelated results (song may not be in this catalog)
			}
			if titleFallback.url == "" {
				titleFallback = appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // CN-first first title match
			}
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, best = sc, appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // best album match
			}
		}
	}
	if best.url != "" {
		return best, true
	}
	// titleFallback (空 url 表示压根没查到) 而不是"没查到就报错":better no link
	// than a wrong-song link (iTunes returns fuzzy unrelated hits for missing songs)。
	return titleFallback, false
}

// resolveAppleMusicMatchViaAlbum finds the best-matching album by name via a
// song-entity search on "artist + album" (entity=album has the same relevance
// gap as entity=song and often can't find this album either — verified), pulls
// that album's full tracklist via iTunes lookup, and matches the title locally.
// A lookup by numeric collection ID isn't ranked/filtered, so it can't miss a
// track that genuinely exists in the catalog the way full-text search can.
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
		// When the album name matches with high confidence (>=200) but track titles differ
		// textually (e.g. localized or traditional/simplified script variants), the album cover
		// remains authoritative because all tracks on an album share identical artwork.
		// Returns cover and album only, omitting track URL since the specific track page was not matched.
		if bestScore >= 200 && bestAlbumCover.cover != "" {
			return bestAlbumCover
		}
	}
	return appleMusicMatch{}
}

// itunesHTTPClient is the shared client for iTunes lookup and search requests.
var itunesHTTPClient = &http.Client{Timeout: 5 * time.Second}

// itunesLookupTracks returns the full tracklist of an album via the lookup
// endpoint (not full-text search, so no relevance-ranking gap). The album
// itself is also returned as a "collection" entry — filtered out here.
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
		// Retain CollectionName, ArtistName, and TrackTimeMillis for downstream albumScore
		// calculations, artist identity verification, and duration matching.
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
	// ArtistName from iTunes Search API, used for storefront artist identity checks.
	ArtistName string `json:"artistName"`
	// TrackTimeMillis from iTunes Search API, used for track duration validation.
	TrackTimeMillis float64 `json:"trackTimeMillis"`
	// ReleaseDate and CollectionArtistName used for album hint candidate ranking and compilation filtering.
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
