package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	qqURLMu    sync.Mutex
	qqURLCache = map[string]qqMusicMatch{}
)

func qqMusicURL(ctx context.Context, artist, title, album string, durationSecs float64) string {
	m := qqMusicMatchCached(ctx, artist, title, album, durationSecs)
	if m.url != "" {
		return m.url
	}
	if title == "" {
		return ""
	}

	return qqSearchFallbackPrefix + "w=" + neturl.QueryEscape(artist+" "+title)
}

const qqSearchFallbackPrefix = "https://y.qq.com/n/ryqq/search?"

func isQQSearchFallbackURL(u string) bool {
	return strings.HasPrefix(u, qqSearchFallbackPrefix)
}

func qqMusicMatchCached(ctx context.Context, artist, title, album string, durationSecs float64) qqMusicMatch {
	if title == "" {
		return qqMusicMatch{}
	}
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(durationSecs))
	qqURLMu.Lock()
	if v, ok := qqURLCache[key]; ok {
		qqURLMu.Unlock()
		return v
	}
	qqURLMu.Unlock()

	m := resolveQQMusicMatch(ctx, artist, title, album, durationSecs)

	if m.url != "" && !m.unreliable {
		qqURLMu.Lock()
		qqURLCache[key] = m
		qqURLMu.Unlock()
	}
	return m
}

type qqSmartboxItem struct {
	Mid    string `json:"mid"`
	Name   string `json:"name"`
	Singer string `json:"singer"`
}

const qqUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

type qqSearchItem struct {
	Mid      string
	Name     string
	Singer   string
	Album    string
	Interval float64
}

type qqClientSearchResp struct {
	Code int `json:"code"`
	Data struct {
		Song struct {
			List []struct {
				Mid      string  `json:"mid"`
				Title    string  `json:"title"`
				Interval float64 `json:"interval"`
				Singer   []struct {
					Name string `json:"name"`
				} `json:"singer"`
				Album struct {
					Name string `json:"name"`
				} `json:"album"`
			} `json:"list"`
		} `json:"song"`
	} `json:"data"`
}

func qqClientSearchItems(resp qqClientSearchResp) []qqSearchItem {
	var out []qqSearchItem
	for _, s := range resp.Data.Song.List {
		if s.Mid == "" {
			continue
		}
		var names []string
		for _, sg := range s.Singer {
			if n := strings.TrimSpace(sg.Name); n != "" {
				names = append(names, n)
			}
		}
		out = append(out, qqSearchItem{
			Mid:      s.Mid,
			Name:     s.Title,
			Singer:   strings.Join(names, "/"),
			Album:    s.Album.Name,
			Interval: s.Interval,
		})
	}
	return out
}

const qqSearchLimit = 10

const qqAlbumLookupBudget = 4

func qqClientSearch(ctx context.Context, query string) ([]qqSearchItem, error) {
	u := "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&new_json=1&t=0&aggr=1&cr=1&p=1&n=" +
		strconv.Itoa(qqSearchLimit) + "&w=" + neturl.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("client_search_cp status %d", resp.StatusCode)
	}
	var out qqClientSearchResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return qqClientSearchItems(out), nil
}

func qqSmartbox(ctx context.Context, query string) []qqSmartboxItem {
	d, _ := qqSmartboxRaw(ctx, query)
	return d.Song.ItemList
}

func qqSmartboxAlbums(ctx context.Context, query string) ([]qqSmartboxItem, error) {
	d, err := qqSmartboxRaw(ctx, query)
	return d.Album.ItemList, err
}

type qqSmartboxCategoryList struct {
	ItemList []qqSmartboxItem `json:"itemlist"`
}

type qqSmartboxData struct {
	Song  qqSmartboxCategoryList `json:"song"`
	Album qqSmartboxCategoryList `json:"album"`
}

func qqSmartboxRaw(ctx context.Context, query string) (qqSmartboxData, error) {
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqSmartboxData{}, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return qqSmartboxData{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqSmartboxData{}, fmt.Errorf("smartbox status %d", resp.StatusCode)
	}
	var out struct {
		Data qqSmartboxData `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return qqSmartboxData{}, err
	}
	return out.Data, nil
}

func qqSearchQueries(artist, title string) []string {
	var out []string
	for _, t := range searchTitleVariants(title) {
		out = append(out, strings.TrimSpace(artist+" "+t))
	}
	return out
}

func qqSearchSongs(ctx context.Context, queries []string, title string) []qqSearchItem {
	var out []qqSearchItem
	seen := map[string]bool{}
	appendNew := func(items []qqSearchItem) {
		for _, it := range items {
			if it.Mid == "" || seen[it.Mid] {
				continue
			}
			seen[it.Mid] = true
			out = append(out, it)
		}
	}
	for _, q := range queries {
		if items, err := qqClientSearch(ctx, q); err == nil {
			appendNew(items)
		}
	}
	if qqSearchNeedsSmartboxSupplement(out, title) {
		for _, q := range queries {
			if items := qqSmartbox(ctx, q); len(items) > 0 {
				appendNew(qqSearchItemsFromSmartbox(items))
				break
			}
		}
	}
	return out
}

func qqSearchNeedsSmartboxSupplement(items []qqSearchItem, title string) bool {
	if len(items) == 0 {
		return true
	}
	want := normLoose(title)
	if want == "" {
		return true
	}
	for _, it := range items {
		if normLoose(it.Name) == want {
			return false
		}
	}
	return true
}

func qqSearchItemsFromSmartbox(items []qqSmartboxItem) []qqSearchItem {
	out := make([]qqSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, qqSearchItem{Mid: it.Mid, Name: it.Name, Singer: it.Singer})
	}
	return out
}

type qqSingerSuggestion struct {
	Name string
	Pic  string
}

func qqSingerSuggestions(ctx context.Context, name string) ([]qqSingerSuggestion, bool) {
	if ctx == nil {
		ctx = context.Background()
	}
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, false
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var out struct {
		Data struct {
			Singer struct {
				ItemList []struct {
					Name string `json:"name"`
					Pic  string `json:"pic"`
				} `json:"itemlist"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, false
	}
	items := make([]qqSingerSuggestion, 0, len(out.Data.Singer.ItemList))
	for _, it := range out.Data.Singer.ItemList {
		items = append(items, qqSingerSuggestion{Name: it.Name, Pic: it.Pic})
	}
	return items, true
}

func qqSingerAvatar(ctx context.Context, name string) (string, bool) {
	items, ok := qqSingerSuggestions(ctx, name)
	if !ok {
		return "", false
	}
	if len(items) == 0 {
		return "", true
	}
	pic := items[0].Pic
	if pic == "" {
		return "", true
	}

	pic = qqCoverAtEdge(pic, "300")
	pic = strings.Replace(pic, "http://", "https://", 1)
	return pic, true
}

func qqArtistCanonicalName(rawArtist string) string {
	items, ok := qqSingerSuggestions(context.Background(), rawArtist)
	if !ok || len(items) == 0 {
		return ""
	}
	return pickQQArtistCanonicalName(items[0].Name, rawArtist)
}

func pickQQArtistCanonicalName(suggestion, rawArtist string) string {
	suggestion = strings.TrimSpace(suggestion)
	if suggestion == "" || !containsHan(suggestion) {
		return ""
	}
	if normLoose(suggestion) == normLoose(rawArtist) {
		return ""
	}
	return suggestion
}

var (
	qqArtistNameMu    sync.Mutex
	qqArtistNameCache = map[string]string{}
	qqArtistNamePath  string
	qqArtistNameDirty bool
)

func loadQQArtistNameCache(path string) {
	qqArtistNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		qqArtistNameMu.Lock()
		qqArtistNameCache = m
		qqArtistNameMu.Unlock()
		log.Printf("cache: loaded %d QQ artist names from %s", len(m), path)
	}
}

func saveQQArtistNameCache() {
	qqArtistNameMu.Lock()
	if !qqArtistNameDirty || qqArtistNamePath == "" {
		qqArtistNameMu.Unlock()
		return
	}
	keep := make(map[string]string, len(qqArtistNameCache))
	for k, v := range qqArtistNameCache {
		if v != "" {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	qqArtistNameDirty = false
	qqArtistNameMu.Unlock()
	if err != nil {
		return
	}
	tmp := qqArtistNamePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, qqArtistNamePath); err != nil {
		log.Printf("save QQ artist name cache: %v", err)
	}
}

func cachedQQArtistCanonicalName(rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}

	qqArtistNameMu.Lock()
	if v, ok := qqArtistNameCache[rawArtist]; ok {
		qqArtistNameMu.Unlock()
		return v
	}
	qqArtistNameMu.Unlock()
	if artistCanonicalCacheOnly {
		return ""
	}

	resolved := qqArtistCanonicalName(rawArtist)

	qqArtistNameMu.Lock()
	qqArtistNameCache[rawArtist] = resolved
	if resolved != "" {
		qqArtistNameDirty = true
	}
	qqArtistNameMu.Unlock()
	saveQQArtistNameCache()
	return resolved
}

func qqSongAlbum(ctx context.Context, mid string) string {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Name string `json:"name"`
			} `json:"album"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return ""
	}
	if len(out.Data) == 0 {
		return ""
	}
	return out.Data[0].Album.Name
}

const qqCoverMaxEdge = "800"

var qqCoverSizeRe = regexp.MustCompile(`(T[0-9]+R)[0-9]+x[0-9]+(M)`)

func qqCoverAtEdge(raw, edge string) string {
	if raw == "" || edge == "" {
		return raw
	}
	if !strings.Contains(raw, "y.qq.com/music/photo_new/") &&
		!strings.Contains(raw, "y.gtimg.cn/music/photo_new/") {
		return raw
	}
	if !qqCoverSizeRe.MatchString(raw) {
		return raw
	}
	return qqCoverSizeRe.ReplaceAllString(raw, "${1}"+edge+"x"+edge+"${2}")
}

func qqAlbumCoverURL(albumMid string) string {
	if albumMid == "" {
		return ""
	}
	return "https://y.qq.com/music/photo_new/T002R" + qqCoverMaxEdge + "x" + qqCoverMaxEdge +
		"M000" + albumMid + ".jpg"
}

func qqSongCoverAndSinger(ctx context.Context, mid string) (cover, singer string) {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Mid string `json:"mid"`
			} `json:"album"`
			Singer []struct {
				Name string `json:"name"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 {
		return "", ""
	}
	d := out.Data[0]
	if d.Album.Mid == "" {
		return "", ""
	}
	if len(d.Singer) > 0 {
		singer = d.Singer[0].Name
	}
	return qqAlbumCoverURL(d.Album.Mid), singer
}

func qqSongCatalogMids(ctx context.Context, mid string) (albumMid, singerMid string) {
	if mid == "" {
		return "", ""
	}
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Mid string `json:"mid"`
			} `json:"album"`
			Singer []struct {
				Mid string `json:"mid"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 {
		return "", ""
	}
	d := out.Data[0]
	if len(d.Singer) > 0 {
		singerMid = d.Singer[0].Mid
	}
	return d.Album.Mid, singerMid
}

func qqCoverFallback(ctx context.Context, artist, title, album string) (cover, canonicalArtist string) {
	if artist == "" || title == "" {
		return "", ""
	}

	singleArtist := len(artistCreditParts(artist)) < 2
	type qqCoverCand struct {
		mid   string
		album string
		exact bool
	}
	var cands []qqCoverCand
	for _, it := range qqSearchSongs(ctx, qqSearchQueries(artist, title), title) {
		if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
			!artistMatches(it.Singer, artist) {
			continue
		}
		cands = append(cands, qqCoverCand{mid: it.Mid, album: it.Album, exact: normLoose(it.Name) == normLoose(title)})
	}
	tryCand := func(c qqCoverCand) (string, string, bool) {
		cover, singer := qqSongCoverAndSinger(ctx, c.mid)
		if cover == "" || !artistMatches(singer, artist) {
			return "", "", false
		}
		if !singleArtist {
			return cover, "", true
		}
		return cover, singer, true
	}
	if album != "" {
		limit := len(cands)
		if limit > 4 {
			limit = 4
		}
		bestIdx, bestScore, bestExact := -1, 0, false
		for i := 0; i < limit; i++ {
			mid := cands[i].mid
			sc := albumScore(qqCandAlbumName(cands[i].album, func() string { return qqSongAlbum(ctx, mid) }), album)
			if sc == 0 && !cands[i].exact {
				continue
			}
			if bestIdx == -1 || (cands[i].exact && !bestExact) || (cands[i].exact == bestExact && sc > bestScore) {
				bestIdx, bestScore, bestExact = i, sc, cands[i].exact
			}
		}
		if bestIdx != -1 {
			if cover, singer, ok := tryCand(cands[bestIdx]); ok {
				return cover, singer
			}
		}
	}
	for _, c := range cands {
		if cover, singer, ok := tryCand(c); ok {
			return cover, singer
		}
	}
	return "", ""
}

func qqArtistOK(strict bool, singer, artist string) bool {
	if artist == "" {
		return true
	}
	if strict {

		return lyricSourceArtistMatches(singer, artist)
	}
	return looseContains(singer, artist)
}

type qqMusicMatch struct {
	url, title, artist, album string
	interval                  float64
	unreliable                bool
}

func resolveQQMusicURL(ctx context.Context, artist, title, album string, durationSecs float64) string {
	return resolveQQMusicMatch(ctx, artist, title, album, durationSecs).url
}

type qqCand struct {
	mid, title, artist string
	album              string
	interval           float64
	exact              bool
}

func qqCollectCandidates(items []qqSearchItem, artist, title string, strict bool) []qqCand {
	var cs []qqCand
	for _, it := range items {
		if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
			!qqArtistOK(strict, it.Singer, artist) {
			continue
		}
		cs = append(cs, qqCand{
			mid: it.Mid, title: it.Name, artist: it.Singer,
			album: it.Album, interval: it.Interval,
			exact: normLoose(it.Name) == normLoose(title),
		})
	}
	return cs
}

func qqCandAlbumName(inline string, fetch func() string) string {
	if inline != "" {
		return inline
	}
	return fetch()
}

func qqCreditSetEqual(singer, artist string) bool {
	if singer == "" || artist == "" {
		return false
	}
	a, b := artistCreditParts(singer), artistCreditParts(artist)
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	left := map[string]int{}
	for _, p := range a {
		left[p]++
	}
	for _, p := range b {
		if left[p] == 0 {
			return false
		}
		left[p]--
	}
	return true
}

func qqMatchFromCand(c qqCand, unreliable bool) qqMusicMatch {
	return qqMusicMatch{
		url: qqSongURL(c.mid), title: c.title, artist: c.artist,
		album: c.album, interval: c.interval, unreliable: unreliable,
	}
}

func qqPickCandidateWithAlbum(cands []qqCand, artist, album string, durationSecs float64, lookupAlbum func(mid string) string) (best qqCand, haveBest bool, bestScore int) {
	bestExact, bestCreditEq, bestFits := false, false, false

	fetched := 0
	for _, c := range cands {
		if c.album == "" && fetched >= qqAlbumLookupBudget {
			continue
		}
		if c.album == "" {
			fetched++
		}
		candAlbum := qqCandAlbumName(c.album, func() string { return lookupAlbum(c.mid) })
		sc := albumScore(candAlbum, album)
		if sc == 0 && !c.exact {
			continue
		}

		creditEq := qqCreditSetEqual(c.artist, artist)

		fits := sourceDurationFits(durationSecs, c.interval)
		better := !haveBest ||
			(fits && !bestFits) ||
			(fits == bestFits && ((c.exact && !bestExact) ||
				(c.exact == bestExact && sc > bestScore) ||
				(c.exact == bestExact && sc == bestScore && creditEq && !bestCreditEq)))
		if better {
			best = c
			best.album = candAlbum
			haveBest, bestScore, bestExact, bestCreditEq, bestFits = true, sc, c.exact, creditEq, fits
		}
	}
	return best, haveBest, bestScore
}

func qqPickCandidate(cands []qqCand, artist string, durationSecs float64) (qqCand, bool) {
	var best qqCand
	haveBest, bestRank := false, -1
	for _, c := range cands {
		rank := 0
		if qqCreditSetEqual(c.artist, artist) {
			rank++
		}
		if c.exact {
			rank += 2
		}

		if sourceDurationFits(durationSecs, c.interval) {
			rank += 4
		}
		if !haveBest || rank > bestRank {
			best, haveBest, bestRank = c, true, rank
		}
	}
	return best, haveBest
}

func resolveQQMusicMatch(ctx context.Context, artist, title, album string, durationSecs float64) qqMusicMatch {
	items := qqSearchSongs(ctx, qqSearchQueries(artist, title), title)
	if len(items) == 0 {

		items = qqSearchSongs(ctx, searchTitleVariants(title), title)
	}

	if lyricSearchItemsTap != nil {
		lyricSearchItemsTap("qq", artist, title, album, durationSecs, items)
	}
	cands := qqCollectCandidates(items, artist, title, true)
	if len(cands) == 0 {
		cands = qqCollectCandidates(items, artist, title, false)
	}
	if len(cands) == 0 {

		m, _ := resolveQQMatchViaAlbum(ctx, artist, title, album)
		return m
	}

	viaAlbumDegraded := false
	if album != "" {
		best, haveBest, bestScore := qqPickCandidateWithAlbum(cands, artist, album, durationSecs, func(mid string) string { return qqSongAlbum(ctx, mid) })
		if haveBest && bestScore > 0 {
			return qqMatchFromCand(best, false)
		}

		var viaAlbum qqMusicMatch
		viaAlbum, viaAlbumDegraded = resolveQQMatchViaAlbum(ctx, artist, title, album)
		if viaAlbum.url != "" {
			return viaAlbum
		}

		if haveBest {
			return qqMatchFromCand(best, viaAlbumDegraded)
		}
	}

	c, ok := qqPickCandidate(cands, artist, durationSecs)
	if !ok {
		return qqMusicMatch{}
	}
	return qqMatchFromCand(c, viaAlbumDegraded)
}

var (
	qqAlbumSongsMu    sync.Mutex
	qqAlbumSongsCache = map[string][]qqAlbumSong{}
)

type qqAlbumSong struct {
	mid, name, singer string
	interval          float64
}

func qqAlbumSongs(ctx context.Context, albumMid string) ([]qqAlbumSong, error) {
	if albumMid == "" {
		return nil, nil
	}
	qqAlbumSongsMu.Lock()
	if v, ok := qqAlbumSongsCache[albumMid]; ok {
		qqAlbumSongsMu.Unlock()
		return v, nil
	}
	qqAlbumSongsMu.Unlock()
	data, err := qqMusicuPost(ctx, "GetAlbumSongList", "music.musichallAlbum.AlbumSongList", map[string]any{
		"albumMid": albumMid, "begin": 0, "num": 100, "order": 2,
	}, qqCommBase)
	if err != nil {
		return nil, err
	}
	var out struct {
		SongList []struct {
			SongInfo struct {
				Mid      string  `json:"mid"`
				Name     string  `json:"name"`
				Interval float64 `json:"interval"`
				Singer   []struct {
					Name string `json:"name"`
				} `json:"singer"`
			} `json:"songInfo"`
		} `json:"songList"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	songs := make([]qqAlbumSong, 0, len(out.SongList))
	for _, s := range out.SongList {
		si := s.SongInfo
		if si.Mid == "" || si.Name == "" {
			continue
		}
		singer := ""
		if len(si.Singer) > 0 {
			singer = si.Singer[0].Name
		}
		songs = append(songs, qqAlbumSong{mid: si.Mid, name: si.Name, singer: singer, interval: si.Interval})
	}
	if len(songs) > 0 {
		qqAlbumSongsMu.Lock()
		qqAlbumSongsCache[albumMid] = songs
		qqAlbumSongsMu.Unlock()
	}
	return songs, nil
}

func qqAlbumIdentityQuery(artist, album string) string {
	s := strings.ToLower(toSimplified(stripParens(album)))
	if a := strings.ToLower(strings.TrimSpace(toSimplified(artist))); a != "" {
		s = strings.ReplaceAll(s, a, " ")
	}
	for _, m := range cjkLiveAlbumMarkers {
		s = strings.ReplaceAll(s, m, " ")
	}
	var out []string
	for _, f := range strings.Fields(s) {
		if liveAlbumMarkerTokens[f] {
			continue
		}
		out = append(out, f)
	}
	return strings.Join(out, " ")
}

func pickQQAlbumTrack(songs []qqAlbumSong, artist, title string) (qqAlbumSong, bool) {
	const (
		tierExact = iota
		tierStripped
		tierAccepted
	)
	type qqTieredAlbumSong struct {
		song qqAlbumSong
		tier int
	}
	var matched []qqTieredAlbumSong
	nt := normLoose(title)
	st := normLoose(stripParens(title))
	for _, s := range songs {
		if !lyricTitleAccepted(s.name, title) {
			continue
		}
		if s.singer != "" && !qqArtistOK(false, s.singer, artist) {
			continue
		}
		tier := tierAccepted
		switch {
		case normLoose(s.name) == nt:
			tier = tierExact
		case normLoose(stripParens(s.name)) == st:
			tier = tierStripped
		}
		matched = append(matched, qqTieredAlbumSong{song: s, tier: tier})
	}
	best := -1
	for _, m := range matched {
		if best == -1 || m.tier < best {
			best = m.tier
		}
	}
	if best == -1 {
		return qqAlbumSong{}, false
	}
	var tied []qqAlbumSong
	for _, m := range matched {
		if m.tier == best {
			tied = append(tied, m.song)
		}
	}
	if len(tied) > 1 && !qqAlbumTiedSongsAreSameTrack(tied) {
		return qqAlbumSong{}, false
	}
	return tied[0], true
}

const qqSameTrackDurationSpreadSecs = 10

func qqAlbumTiedSongsAreSameTrack(tied []qqAlbumSong) bool {
	if len(tied) == 0 {
		return false
	}
	first := tied[0]
	if first.interval <= 0 {
		return false
	}
	minD, maxD := first.interval, first.interval
	for _, s := range tied[1:] {
		if normLoose(s.name) != normLoose(first.name) {
			return false
		}
		if normLoose(s.singer) != normLoose(first.singer) {
			return false
		}
		if s.interval <= 0 {
			return false
		}
		if s.interval < minD {
			minD = s.interval
		}
		if s.interval > maxD {
			maxD = s.interval
		}
	}
	return maxD-minD <= qqSameTrackDurationSpreadSecs
}

func resolveQQMatchViaAlbum(ctx context.Context, artist, title, album string) (m qqMusicMatch, degraded bool) {
	if album == "" || title == "" {
		return qqMusicMatch{}, false
	}

	localIdentity := albumIdentityTokens(artist, album)
	if len(localIdentity) == 0 {
		return qqMusicMatch{}, false
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	var queries []string
	seen := map[string]bool{}
	addQ := func(q string) {
		q = strings.TrimSpace(q)
		if q == "" || seen[q] {
			return
		}
		seen[q] = true
		queries = append(queries, q)
	}
	identity := qqAlbumIdentityQuery(artist, album)
	addQ(artist + " " + stripParens(album))
	if identity != "" {
		addQ(artist + " " + identity)
		addQ(identity)
	}
	var bestAlbum qqSmartboxItem
	bestScore := 0
	for _, q := range queries {
		items, err := qqSmartboxAlbums(ctx, q)
		if err != nil {
			degraded = true
		}
		for _, it := range items {
			if it.Mid == "" || !qqArtistOK(false, it.Singer, artist) {
				continue
			}

			sc := albumScore(it.Name, album)
			if sc == 0 {
				continue
			}
			candIdentity := albumIdentityTokens(artist, it.Name)
			shared := false
			for t := range candIdentity {
				if localIdentity[t] {
					shared = true
					break
				}
			}
			if !shared {
				continue
			}
			if sc > bestScore {
				bestAlbum, bestScore = it, sc
			}
		}
		if bestScore > 0 {
			break
		}
	}
	if bestScore == 0 {
		return qqMusicMatch{}, degraded
	}
	songs, err := qqAlbumSongs(ctx, bestAlbum.Mid)
	if err != nil {
		degraded = true
	}

	picked, ok := pickQQAlbumTrack(songs, artist, title)
	if !ok {
		return qqMusicMatch{}, degraded
	}
	return qqMusicMatch{
		url: qqSongURL(picked.mid), title: picked.name, artist: picked.singer,
		album: bestAlbum.Name, interval: picked.interval,
	}, degraded
}

func qqSongURL(mid string) string {
	if mid == "" {
		return ""
	}
	return "https://y.qq.com/n/ryqq/songDetail/" + mid
}

func qqMidFromURL(u string) string {
	const marker = "/songDetail/"
	i := strings.Index(u, marker)
	if i < 0 {
		return ""
	}
	mid := u[i+len(marker):]
	if j := strings.IndexAny(mid, "/?#"); j >= 0 {
		mid = mid[:j]
	}
	return mid
}

var (
	qqLyricMu    sync.Mutex
	qqLyricCache = map[string]qqLyricResult{}
)

type qqLyricResult struct {
	lrc          string
	instrumental bool
}

func qqLyric(ctx context.Context, mid string) qqLyricResult {
	if mid == "" {
		return qqLyricResult{}
	}
	qqLyricMu.Lock()
	if v, ok := qqLyricCache[mid]; ok {
		qqLyricMu.Unlock()
		return v
	}
	qqLyricMu.Unlock()
	l := resolveQQLyric(ctx, mid)
	if l.lrc != "" || l.instrumental {
		qqLyricMu.Lock()
		qqLyricCache[mid] = l
		qqLyricMu.Unlock()
	}
	return l
}

func resolveQQLyric(ctx context.Context, mid string) qqLyricResult {
	u := "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?format=json&nobase64=1&g_tk=5381&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqLyricResult{}
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return qqLyricResult{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqLyricResult{}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return qqLyricResult{}
	}

	s := string(raw)
	i, j := strings.IndexByte(s, '{'), strings.LastIndexByte(s, '}')
	if i < 0 || j <= i {
		return qqLyricResult{}
	}
	var out struct {
		Lyric string `json:"lyric"`
	}
	if err := json.Unmarshal([]byte(s[i:j+1]), &out); err != nil {
		return qqLyricResult{}
	}

	if isInstrumentalPlaceholderLyric(out.Lyric) {
		return qqLyricResult{instrumental: true}
	}
	if l := out.Lyric; isTimedLRC(l) {
		return qqLyricResult{lrc: l}
	}
	return qqLyricResult{}
}

type qqSessionInfo struct {
	uid    string
	sid    string
	userip string
}

var (
	qqSessionMu   sync.Mutex
	qqSessionInit bool
	qqSessionVal  qqSessionInfo
)

var qqCommBase = map[string]any{
	"ct": 11, "cv": "1003006", "v": "1003006",
	"os_ver":    "15",
	"phonetype": "24122RKC7C",
	"rom":       "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
	"tmeAppID":  "qqmusiclight",
	"nettype":   "NETWORK_WIFI",
	"udid":      "0",
}

func qqComm(sess qqSessionInfo) map[string]any {
	comm := make(map[string]any, len(qqCommBase)+3)
	for k, v := range qqCommBase {
		comm[k] = v
	}
	comm["uid"], comm["sid"], comm["userip"] = sess.uid, sess.sid, sess.userip
	return comm
}

func qqMusicuPost(ctx context.Context, method, module string, param any, comm map[string]any) (json.RawMessage, error) {
	reqBody := struct {
		Comm    map[string]any `json:"comm"`
		Request struct {
			Method string `json:"method"`
			Module string `json:"module"`
			Param  any    `json:"param"`
		} `json:"request"`
	}{Comm: comm}
	reqBody.Request.Method = method
	reqBody.Request.Module = module
	reqBody.Request.Param = param
	raw, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://u.y.qq.com/cgi-bin/musicu.fcg", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Cookie", "tmeLoginType=-1;")
	req.Header.Set("User-Agent", "okhttp/3.14.9")
	resp, err := doHTTPTracked(lyricHTTPClient(8*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Code    int `json:"code"`
		Request struct {
			Code int             `json:"code"`
			Data json.RawMessage `json:"data"`
		} `json:"request"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != 0 || out.Request.Code != 0 {
		return nil, fmt.Errorf("qq musicu api error: code=%d request.code=%d", out.Code, out.Request.Code)
	}
	return out.Request.Data, nil
}

func qqEnsureSession(ctx context.Context) qqSessionInfo {
	qqSessionMu.Lock()
	defer qqSessionMu.Unlock()
	if qqSessionInit {
		return qqSessionVal
	}
	qqSessionInit = true
	data, err := qqMusicuPost(ctx, "GetSession", "music.getSession.session", map[string]any{
		"caller": 0, "uid": "0", "vkey": 0,
	}, qqCommBase)
	if err != nil {
		return qqSessionInfo{}
	}
	var out struct {
		Session struct {
			UID    json.Number `json:"uid"`
			SID    string      `json:"sid"`
			UserIP string      `json:"userip"`
		} `json:"session"`
	}
	if err := json.Unmarshal(data, &out); err != nil || out.Session.SID == "" {
		return qqSessionInfo{}
	}
	qqSessionVal = qqSessionInfo{uid: out.Session.UID.String(), sid: out.Session.SID, userip: out.Session.UserIP}
	return qqSessionVal
}

type qqSongMeta struct {
	id       int64
	interval float64

	language int
}

var (
	qqSongMetaMu    sync.Mutex
	qqSongMetaCache = map[string]qqSongMeta{}
)

func qqSongMetaCachedOnly(mid string) qqSongMeta {
	if mid == "" {
		return qqSongMeta{}
	}
	qqSongMetaMu.Lock()
	defer qqSongMetaMu.Unlock()
	return qqSongMetaCache[mid]
}

func qqSongMetaByMid(ctx context.Context, mid string) qqSongMeta {
	if mid == "" {
		return qqSongMeta{}
	}
	qqSongMetaMu.Lock()
	if v, ok := qqSongMetaCache[mid]; ok {
		qqSongMetaMu.Unlock()
		return v
	}
	qqSongMetaMu.Unlock()

	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqSongMeta{}
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return qqSongMeta{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqSongMeta{}
	}
	var out struct {
		Data []struct {
			ID       int64   `json:"id"`
			Interval float64 `json:"interval"`
			Language int     `json:"language"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 || out.Data[0].ID == 0 {
		return qqSongMeta{}
	}
	m := qqSongMeta{id: out.Data[0].ID, interval: out.Data[0].Interval, language: out.Data[0].Language}
	qqSongMetaMu.Lock()
	qqSongMetaCache[mid] = m
	qqSongMetaMu.Unlock()
	return m
}

func qqCanonicalLanguage(n int) string {
	switch n {
	case 0:
		return songLanguageMandarin
	case 1:
		return songLanguageCantonese
	default:
		return ""
	}
}

var qrcDESKey = []byte("!@#)(*$%123ZXC!@!@#)(NHL")

func decryptQRC(hexStr string) string {
	raw, err := hex.DecodeString(hexStr)
	if err != nil || len(raw) == 0 || len(raw)%8 != 0 {
		return ""
	}
	dec := qm3DESDecrypt(qrcDESKey, raw)
	if dec == nil {
		return ""
	}
	zr, err := zlib.NewReader(bytes.NewReader(dec))
	if err != nil {
		return ""
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		return ""
	}
	return string(out)
}

var qrcContentRegex = regexp.MustCompile(`(?s)LyricContent="(.*)"\s*/>`)

func extractQRCLyricContent(xmlText string) string {
	m := qrcContentRegex.FindStringSubmatch(xmlText)
	if m == nil {
		return ""
	}
	return html.UnescapeString(m[1])
}

var qqWordRegex = regexp.MustCompile(`([^\[\]()\n]+)\((\d+),(\d+)\)`)

func qrcToYRC(qrc string) string {
	if qrc == "" {
		return ""
	}
	return qqWordRegex.ReplaceAllString(qrc, "($2,$3,0)$1")
}

type qqQRCResult struct {
	yrc, tr, roma string
	kana          string
}

func qqQRCLyric(ctx context.Context, mid, artist, title, album string, durationSecs float64) qqQRCResult {
	if mid == "" {
		return qqQRCResult{}
	}
	sess := qqEnsureSession(ctx)
	if sess.sid == "" {
		return qqQRCResult{}
	}
	meta := qqSongMetaByMid(ctx, mid)
	if meta.id == 0 {
		return qqQRCResult{}
	}
	interval := meta.interval
	if interval <= 0 {
		interval = durationSecs
	}
	param := map[string]any{
		"albumName":  base64.StdEncoding.EncodeToString([]byte(album)),
		"crypt":      1,
		"ct":         19,
		"cv":         2111,
		"interval":   int(interval),
		"lrc_t":      0,
		"qrc":        1,
		"qrc_t":      0,
		"roma":       1,
		"roma_t":     0,
		"singerName": base64.StdEncoding.EncodeToString([]byte(artist)),
		"songID":     meta.id,
		"songName":   base64.StdEncoding.EncodeToString([]byte(title)),
		"trans":      1,
		"trans_t":    0,
		"type":       0,
	}
	data, err := qqMusicuPost(ctx, "GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", param, qqComm(sess))
	if err != nil {
		return qqQRCResult{}
	}
	var out struct {
		Lyric string      `json:"lyric"`
		Trans string      `json:"trans"`
		Roma  string      `json:"roma"`
		QrcT  json.Number `json:"qrc_t"`
		LrcT  json.Number `json:"lrc_t"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return qqQRCResult{}
	}

	res := qqQRCResult{tr: qqAuxiliaryLRC(out.Trans), roma: qqAuxiliaryLRC(out.Roma)}
	if out.Lyric == "" {
		return res
	}
	t := out.QrcT.String()
	if t == "" || t == "0" {
		t = out.LrcT.String()
	}
	if t == "" || t == "0" {
		return res
	}
	decrypted := decryptQRC(out.Lyric)
	if decrypted == "" {
		return res
	}
	content := extractQRCLyricContent(decrypted)
	if content == "" {
		return res
	}

	res.kana, content = splitQRCKanaLine(content)
	res.yrc = qrcToYRC(content)
	return res
}

func splitQRCKanaLine(content string) (kana, rest string) {
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[kana:") && strings.HasSuffix(trimmed, "]") {
			return trimmed, strings.Join(append(lines[:i:i], lines[i+1:]...), "\n")
		}
	}
	return "", content
}

func attachKanaLine(lrc, kana string) string {
	if lrc == "" || kana == "" || strings.Contains(lrc, "[kana:") {
		return lrc
	}
	return kana + "\n" + lrc
}

var (
	qrcLineHeadRegex   = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
	qrcWordTimingRegex = regexp.MustCompile(`\(\d+,\d+\)`)
)

func qqAuxiliaryLRC(cipherHex string) string {
	if strings.TrimSpace(cipherHex) == "" {
		return ""
	}
	decrypted := decryptQRC(cipherHex)
	if decrypted == "" {
		return ""
	}
	return qqAuxiliaryPlainToLRC(decrypted)
}

func qqAuxiliaryPlainToLRC(plain string) string {
	if c := extractQRCLyricContent(plain); c != "" {
		plain = c
	}
	var lrc string
	if hasQRCLineTiming(plain) {
		lrc = qrcToLineLRC(plain)
	} else {
		lrc = cleanQQAuxiliaryLRC(plain)
	}
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

func hasQRCLineTiming(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		if qrcLineHeadRegex.MatchString(strings.TrimSpace(line)) {
			return true
		}
	}
	return false
}

func qrcToLineLRC(qrc string) string {
	var out []string
	for _, line := range strings.Split(qrc, "\n") {
		line = strings.TrimSpace(line)
		if isLRCOffsetTag(line) {
			out = append(out, line)
			continue
		}
		m := qrcLineHeadRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		startMs, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		text := qrcWordTimingRegex.ReplaceAllString(line[len(m[0]):], "")
		text = strings.Join(strings.Fields(text), " ")
		if text == "" || text == "//" || isQQTranslationNotice(text) {
			continue
		}
		out = append(out, fmt.Sprintf("[%02d:%02d.%03d]%s", startMs/60000, (startMs/1000)%60, startMs%1000, text))
	}
	return strings.Join(out, "\n")
}

func cleanQQAuxiliaryLRC(lrc string) string {
	var out []string
	for _, line := range strings.Split(lrc, "\n") {
		trimmed := strings.TrimSpace(line)
		if isLRCOffsetTag(trimmed) {
			out = append(out, trimmed)
			continue
		}
		if !strings.HasPrefix(trimmed, "[") || !lrcTimestampRe.MatchString(trimmed) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(trimmed, ""))
		if text == "" || text == "//" || isQQTranslationNotice(text) {
			continue
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\n")
}

func isLRCOffsetTag(line string) bool {
	return strings.HasPrefix(strings.ToLower(line), "[offset:")
}

func isQQTranslationNotice(text string) bool {
	return strings.Contains(text, "翻译作品的著作权") ||
		(strings.Contains(text, "QQ音乐") && strings.Contains(text, "著作权"))
}
