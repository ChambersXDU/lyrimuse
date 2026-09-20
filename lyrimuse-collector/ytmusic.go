package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ytmusicResult struct {
	lyrics, title, artist, album, cover string

	durationSecs float64
}

const (
	ytmusicDomain      = "https://music.youtube.com"
	ytmusicBaseAPI     = ytmusicDomain + "/youtubei/v1/"
	ytmusicHTTPTimeout = 6 * time.Second

	ytmusicUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"

	ytmusicSongsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

	ytmusicWebClientName = "WEB_REMIX"

	ytmusicMobileClientName    = "ANDROID_MUSIC"
	ytmusicMobileClientVersion = "7.21.50"
)

var (
	ytmusicMu    sync.Mutex
	ytmusicCache = map[string]ytmusicResult{}

	ytmusicVisitorMu sync.Mutex
	ytmusicVisitorID string

	ytmusicVisitorFetchMu sync.Mutex

	ytmusicLastFailureMu     sync.Mutex
	ytmusicLastFailureReason string
)

func ytmusicSetLastFailureReason(reason string) {
	ytmusicLastFailureMu.Lock()
	ytmusicLastFailureReason = reason
	ytmusicLastFailureMu.Unlock()
}

func ytmusicLastFailureReasonNow() string {
	ytmusicLastFailureMu.Lock()
	defer ytmusicLastFailureMu.Unlock()
	return ytmusicLastFailureReason
}

var ytmusicDoFetchVisitorID func(ctx context.Context) string

func ytmusicCachedVisitorID() string {
	ytmusicVisitorMu.Lock()
	defer ytmusicVisitorMu.Unlock()
	return ytmusicVisitorID
}

func ytmusicEnsureVisitorID(ctx context.Context) string {
	if v := ytmusicCachedVisitorID(); v != "" {
		return v
	}
	ytmusicVisitorFetchMu.Lock()
	defer ytmusicVisitorFetchMu.Unlock()
	if v := ytmusicCachedVisitorID(); v != "" {
		return v
	}
	var v string
	if ytmusicDoFetchVisitorID != nil {
		v = ytmusicDoFetchVisitorID(ctx)
	} else {
		v = ytmusicFetchVisitorID(ctx)
	}
	if v != "" {
		ytmusicVisitorMu.Lock()
		ytmusicVisitorID = v
		ytmusicVisitorMu.Unlock()
	}
	return v
}

var ytmusicVisitorDataRe = regexp.MustCompile(`ytcfg\.set\s*\(\s*(\{.+?\})\s*\)\s*;`)

func ytmusicFetchVisitorID(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ytmusicDomain+"/", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	resp, err := doHTTPTracked(lyricHTTPClient(8*time.Second), req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return ""
	}
	html := string(body)
	v := ytmusicExtractVisitorID(html)
	if v == "" {

		if strings.Contains(strings.ToLower(html), "not available in your area") {

			ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
		}
	}
	return v
}

func ytmusicExtractVisitorID(html string) string {
	m := ytmusicVisitorDataRe.FindStringSubmatch(html)
	if len(m) < 2 {
		return ""
	}
	var cfg struct {
		VisitorData string `json:"VISITOR_DATA"`
	}
	if json.Unmarshal([]byte(m[1]), &cfg) != nil {
		return ""
	}
	return cfg.VisitorData
}

func ytmusicContext(clientName, clientVersion string) map[string]any {
	return map[string]any{
		"context": map[string]any{
			"client": map[string]any{"clientName": clientName, "clientVersion": clientVersion},
			"user":   map[string]any{},
		},
	}
}

func ytmusicWebClientVersion() string {
	return "1." + time.Now().UTC().Format("20060102") + ".01.00"
}

func ytmusicPost(ctx context.Context, endpoint string, body map[string]any, visitorID string) ([]byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ytmusicBaseAPI+endpoint+"?alt=json", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", ytmusicDomain)
	if visitorID != "" {
		req.Header.Set("X-Goog-Visitor-Id", visitorID)
	}
	resp, err := doHTTPTracked(lyricHTTPClient(ytmusicHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

type ytmusicSearchItem struct {
	MusicResponsiveListItemRenderer struct {
		FlexColumns []struct {
			MusicResponsiveListItemFlexColumnRenderer struct {
				Text struct {
					Runs []struct {
						Text string `json:"text"`
					} `json:"runs"`
				} `json:"text"`
			} `json:"musicResponsiveListItemFlexColumnRenderer"`
		} `json:"flexColumns"`
		Thumbnail struct {
			MusicThumbnailRenderer struct {
				Thumbnail struct {
					Thumbnails []struct {
						URL   string `json:"url"`
						Width int    `json:"width"`
					} `json:"thumbnails"`
				} `json:"thumbnail"`
			} `json:"musicThumbnailRenderer"`
		} `json:"thumbnail"`
		Overlay struct {
			MusicItemThumbnailOverlayRenderer struct {
				Content struct {
					MusicPlayButtonRenderer struct {
						PlayNavigationEndpoint struct {
							WatchEndpoint struct {
								VideoID                            string `json:"videoId"`
								WatchEndpointMusicSupportedConfigs struct {
									WatchEndpointMusicConfig struct {
										MusicVideoType string `json:"musicVideoType"`
									} `json:"watchEndpointMusicConfig"`
								} `json:"watchEndpointMusicSupportedConfigs"`
							} `json:"watchEndpoint"`
						} `json:"playNavigationEndpoint"`
					} `json:"musicPlayButtonRenderer"`
				} `json:"content"`
			} `json:"musicItemThumbnailOverlayRenderer"`
		} `json:"overlay"`
	} `json:"musicResponsiveListItemRenderer"`
}

type ytmusicParsedSearchItem struct {
	videoID              string
	title, artist, album string
	durationSecs         float64
	cover                string
	isATV                bool
}

func ytmusicParseSearchItem(item ytmusicSearchItem) (ytmusicParsedSearchItem, bool) {
	r := item.MusicResponsiveListItemRenderer
	flex := r.FlexColumns
	if len(flex) < 2 {
		return ytmusicParsedSearchItem{}, false
	}
	joinRuns := func(i int) string {
		var b strings.Builder
		for _, run := range flex[i].MusicResponsiveListItemFlexColumnRenderer.Text.Runs {
			b.WriteString(run.Text)
		}
		return b.String()
	}
	title := joinRuns(0)
	parts := strings.Split(joinRuns(1), " • ")
	if title == "" || len(parts) < 2 {
		return ytmusicParsedSearchItem{}, false
	}
	artist := parts[0]
	durationText := parts[len(parts)-1]
	album := strings.Join(parts[1:len(parts)-1], " • ")
	watch := r.Overlay.MusicItemThumbnailOverlayRenderer.Content.MusicPlayButtonRenderer.PlayNavigationEndpoint.WatchEndpoint
	videoID := watch.VideoID
	if videoID == "" {
		return ytmusicParsedSearchItem{}, false
	}
	var cover string
	thumbs := r.Thumbnail.MusicThumbnailRenderer.Thumbnail.Thumbnails
	for _, t := range thumbs {
		if cover == "" || t.Width > 0 {
			cover = t.URL
		}
	}
	return ytmusicParsedSearchItem{
		videoID:      videoID,
		title:        title,
		artist:       artist,
		album:        album,
		durationSecs: ytmusicParseDurationText(durationText),
		cover:        cover,
		isATV:        watch.WatchEndpointMusicSupportedConfigs.WatchEndpointMusicConfig.MusicVideoType == "MUSIC_VIDEO_TYPE_ATV",
	}, true
}

func ytmusicParseDurationText(s string) float64 {
	segs := strings.Split(strings.TrimSpace(s), ":")
	if len(segs) < 2 || len(segs) > 3 {
		return 0
	}
	var total float64
	for _, seg := range segs {
		n, err := strconv.Atoi(seg)
		if err != nil || n < 0 {
			return 0
		}
		total = total*60 + float64(n)
	}
	return total
}

const ytmusicSearchDurationTolerance = 0.25

func ytmusicPickSearchItem(items []ytmusicParsedSearchItem, artist, title, album string, durationSecs float64) (ytmusicParsedSearchItem, bool) {
	var best ytmusicParsedSearchItem
	found := false
	bestDiff := -1.0
	bestATV := false
	for _, it := range items {
		if !lyricTitleAccepted(it.title, title) || !lyricSourceArtistMatches(it.artist, artist) {
			continue
		}
		if versionTagsMismatch(title, album, it.title, it.album) {
			continue
		}
		if !found {
			best, found, bestATV = it, true, it.isATV
			if durationSecs > 0 && it.durationSecs > 0 {
				bestDiff = mathAbs(it.durationSecs-durationSecs) / durationSecs
			}
			continue
		}

		if bestATV && !it.isATV {
			continue
		}
		promote := it.isATV && !bestATV
		if !promote && durationSecs > 0 && it.durationSecs > 0 {
			diff := mathAbs(it.durationSecs-durationSecs) / durationSecs
			if diff > ytmusicSearchDurationTolerance {
				continue
			}
			if bestDiff < 0 || diff < bestDiff {
				promote, bestDiff = true, diff
			}
		}
		if promote {
			best, bestATV = it, it.isATV
		}
	}
	return best, found
}

func mathAbs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

func ytmusicSearchSong(ctx context.Context, artist, title, album string, durationSecs float64, visitorID string) (ytmusicParsedSearchItem, bool) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["query"] = strings.TrimSpace(artist + " " + title)
	body["params"] = ytmusicSongsFilterParams
	raw, err := ytmusicPost(ctx, "search", body, visitorID)
	if err != nil || len(raw) == 0 {
		return ytmusicParsedSearchItem{}, false
	}
	items := ytmusicExtractSearchItems(raw)
	if len(items) == 0 {
		return ytmusicParsedSearchItem{}, false
	}
	var parsed []ytmusicParsedSearchItem
	for _, it := range items {
		if p, ok := ytmusicParseSearchItem(it); ok {
			parsed = append(parsed, p)
		}
	}
	return ytmusicPickSearchItem(parsed, artist, title, album, durationSecs)
}

func ytmusicExtractSearchItems(raw []byte) []ytmusicSearchItem {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return nil
	}
	var items []ytmusicSearchItem
	ytmusicWalkJSON(tree, func(node map[string]any) {
		v, ok := node["musicResponsiveListItemRenderer"]
		if !ok {
			return
		}
		b, err := json.Marshal(map[string]any{"musicResponsiveListItemRenderer": v})
		if err != nil {
			return
		}
		var item ytmusicSearchItem
		if json.Unmarshal(b, &item) == nil {
			items = append(items, item)
		}
	})
	return items
}

func ytmusicWalkJSON(node any, visit func(map[string]any)) {
	switch v := node.(type) {
	case map[string]any:
		visit(v)
		for _, child := range v {
			ytmusicWalkJSON(child, visit)
		}
	case []any:
		for _, child := range v {
			ytmusicWalkJSON(child, visit)
		}
	}
}

func ytmusicLyricsBrowseID(raw []byte) string {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return ""
	}
	var browseID string
	ytmusicWalkJSON(tree, func(node map[string]any) {
		if browseID != "" {
			return
		}
		be, ok := node["browseEndpoint"].(map[string]any)
		if !ok {
			return
		}
		id, _ := be["browseId"].(string)
		if id == "" {
			return
		}
		cfg, _ := be["browseEndpointContextSupportedConfigs"].(map[string]any)
		musicCfg, _ := cfg["browseEndpointContextMusicConfig"].(map[string]any)
		pageType, _ := musicCfg["pageType"].(string)
		if pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS" {
			browseID = id
		}
	})
	return browseID
}

func ytmusicFetchLyricsBrowseID(ctx context.Context, videoID, visitorID string) string {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["videoId"] = videoID
	body["playlistId"] = "RDAMVM" + videoID
	body["enablePersistentPlaylistPanel"] = true
	body["isAudioOnly"] = true
	body["tunerSettingValue"] = "AUTOMIX_SETTING_NORMAL"
	body["watchEndpointMusicSupportedConfigs"] = map[string]any{
		"watchEndpointMusicConfig": map[string]any{
			"hasPersistentPlaylistPanel": true,
			"musicVideoType":             "MUSIC_VIDEO_TYPE_ATV",
		},
	}
	raw, err := ytmusicPost(ctx, "next", body, visitorID)
	if err != nil || len(raw) == 0 {
		return ""
	}
	return ytmusicLyricsBrowseID(raw)
}

type ytmusicLyricLine struct {
	text           string
	startMs, endMs int
}

func ytmusicParseTimedLyrics(raw []byte) ([]ytmusicLyricLine, string) {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return nil, ""
	}
	var lines []ytmusicLyricLine
	var source string
	ytmusicWalkJSON(tree, func(node map[string]any) {
		if lines != nil {
			return
		}
		raw, ok := node["timedLyricsData"].([]any)
		if !ok || len(raw) == 0 {
			return
		}
		var parsed []ytmusicLyricLine
		for _, entry := range raw {
			e, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			text, _ := e["lyricLine"].(string)
			cue, _ := e["cueRange"].(map[string]any)
			startStr, _ := cue["startTimeMilliseconds"].(string)
			endStr, _ := cue["endTimeMilliseconds"].(string)
			start, errS := strconv.Atoi(startStr)
			end, errE := strconv.Atoi(endStr)
			if errS != nil || errE != nil || end < start {
				continue
			}
			parsed = append(parsed, ytmusicLyricLine{text: text, startMs: start, endMs: end})
		}
		if len(parsed) == 0 {
			return
		}
		lines = parsed
		if s, ok := node["sourceMessage"].(string); ok {
			source = s
		}
	})
	return lines, source
}

func ytmusicBuildLRC(lines []ytmusicLyricLine) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(formatLRCTime(l.startMs))
		b.WriteString(l.text)
		b.WriteString("\n")
	}
	return b.String()
}

func ytmusicFetchTimedLyrics(ctx context.Context, browseID, visitorID string) (string, string) {
	body := ytmusicContext(ytmusicMobileClientName, ytmusicMobileClientVersion)
	body["browseId"] = browseID
	raw, err := ytmusicPost(ctx, "browse", body, visitorID)
	if err != nil || len(raw) == 0 {
		return "", ""
	}
	lines, source := ytmusicParseTimedLyrics(raw)
	if len(lines) == 0 {
		return "", ""
	}
	return ytmusicBuildLRC(lines), source
}

func ytmusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) ytmusicResult {
	if title == "" {
		return ytmusicResult{}
	}
	key := artist + "|" + title + "|" + album
	ytmusicMu.Lock()
	if v, ok := ytmusicCache[key]; ok {
		ytmusicMu.Unlock()
		return v
	}
	ytmusicMu.Unlock()

	r := resolveYTMusicLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		ytmusicMu.Lock()
		ytmusicCache[key] = r
		ytmusicMu.Unlock()
	}
	return r
}

func resolveYTMusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) ytmusicResult {
	visitorID := ytmusicEnsureVisitorID(ctx)
	if visitorID == "" {
		return ytmusicResult{}
	}
	item, ok := ytmusicSearchSong(ctx, artist, title, album, durationSecs, visitorID)
	if !ok {
		return ytmusicResult{}
	}
	browseID := ytmusicFetchLyricsBrowseID(ctx, item.videoID, visitorID)
	if browseID == "" {
		return ytmusicResult{}
	}
	lrc, source := ytmusicFetchTimedLyrics(ctx, browseID, visitorID)
	if !isTimedLRC(lrc) {
		return ytmusicResult{}
	}

	if !ytmusicIsLyricFindSource(source) {
		return ytmusicResult{}
	}
	return ytmusicResult{
		lyrics: lrc, title: item.title, artist: item.artist, album: item.album,
		durationSecs: item.durationSecs, cover: item.cover,
	}
}

func ytmusicIsLyricFindSource(source string) bool {
	return strings.Contains(strings.ToLower(source), "lyricfind")
}
