package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type kuwoResult struct {
	lyrics, title, artist, album string

	durationSecs float64

	cover string
}

var (
	kuwoMu    sync.Mutex
	kuwoCache = map[string]kuwoResult{}
)

func kuwoLyric(ctx context.Context, artist, title, album string, durationSecs float64) kuwoResult {
	if title == "" {
		return kuwoResult{}
	}
	key := artist + "|" + title + "|" + album
	kuwoMu.Lock()
	if v, ok := kuwoCache[key]; ok {
		kuwoMu.Unlock()
		return v
	}
	kuwoMu.Unlock()

	r := resolveKuwoLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		kuwoMu.Lock()
		kuwoCache[key] = r
		kuwoMu.Unlock()
	}
	return r
}

type kuwoSearchItem struct {
	MusicRID string `json:"MUSICRID"`
	SongName string `json:"SONGNAME"`
	Artist   string `json:"ARTIST"`
	Album    string `json:"ALBUM"`
	Duration string `json:"DURATION"`

	WebAlbumPicShort string `json:"web_albumpic_short"`
}

func kuwoCoverURL(short string) string {
	short = strings.TrimSpace(short)
	if short == "" {
		return ""
	}
	if parts := strings.SplitN(short, "/", 2); len(parts) == 2 {
		short = "500/" + parts[1]
	}
	return "https://img1.kuwo.cn/star/albumcover/" + short
}

func kuwoSearch(ctx context.Context, artist, title string) ([]kuwoSearchItem, error) {
	q := strings.TrimSpace(title + " " + artist)
	u := "https://search.kuwo.cn/r.s?all=" + neturl.QueryEscape(q) +
		"&ft=music&itemset=web_2013&client=kt&pn=0&rn=10&rformat=json&encoding=utf8&pcjson=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://www.kuwo.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Abslist []kuwoSearchItem `json:"abslist"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Abslist, nil
}

func kuwoMusicID(rid string) string {
	idx := strings.LastIndex(rid, "_")
	if idx < 0 || idx == len(rid)-1 {
		return ""
	}
	return rid[idx+1:]
}

func kuwoDurationSecs(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if v, err := strconv.ParseFloat(s, 64); err == nil && v >= 0 {
		return v
	}
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return 0
	}
	m, errM := strconv.Atoi(parts[0])
	sec, errS := strconv.ParseFloat(parts[1], 64)
	if errM != nil || errS != nil || m < 0 || sec < 0 {
		return 0
	}
	return float64(m)*60 + sec
}

type kuwoLyricLine struct {
	Time      string `json:"time"`
	LineLyric string `json:"lineLyric"`
}

func kuwoFetchLyric(ctx context.Context, musicID string) ([]kuwoLyricLine, error) {
	u := "https://kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=" + neturl.QueryEscape(musicID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://kuwo.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Data struct {
			LrcList []kuwoLyricLine `json:"lrclist"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Data.LrcList, nil
}

func kuwoNormalizeTime(raw string) (string, bool) {
	s, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil {
		return "", false
	}
	if s < 0 {
		s = 0
	}
	return fmt.Sprintf("%02d:%05.2f", int(s/60), math.Mod(s, 60)), true
}

func kuwoBuildLRC(lines []kuwoLyricLine) string {
	var b strings.Builder
	for _, l := range lines {
		ts, ok := kuwoNormalizeTime(l.Time)
		if !ok {
			continue
		}
		text := strings.TrimSpace(l.LineLyric)
		if text == "" {
			continue
		}
		b.WriteString("[" + ts + "]" + text + "\n")
	}
	return b.String()
}

const kuwoScoreDurationTolerance = 0.25

func kuwoCandidateScore(item kuwoSearchItem, artist, title, album string, durationSecs float64) int {
	if !lyricTitleAccepted(item.SongName, title) {
		return -1
	}
	if !lyricSourceArtistMatches(item.Artist, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, item.SongName, item.Album) {
		return -1
	}
	score := 100
	if durationSecs > 0 {
		d := kuwoDurationSecs(item.Duration)
		if d <= 0 {
			return score
		}
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > kuwoScoreDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

const kuwoMaxCandidatesToFetch = 5

func resolveKuwoLyric(ctx context.Context, artist, title, album string, durationSecs float64) kuwoResult {
	items, err := kuwoSearch(ctx, artist, title)
	if err != nil || len(items) == 0 {
		return kuwoResult{}
	}

	type scoredItem struct {
		item  kuwoSearchItem
		score int
	}
	var candidates []scoredItem
	for _, it := range items {
		if it.MusicRID == "" {
			continue
		}
		if s := kuwoCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
			candidates = append(candidates, scoredItem{it, s})
		}
	}
	if len(candidates) == 0 {
		return kuwoResult{}
	}

	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > kuwoMaxCandidatesToFetch {
		candidates = candidates[:kuwoMaxCandidatesToFetch]
	}

	type fetched struct {
		lrc string
		it  kuwoSearchItem
	}
	fetchedByRank := make([]*fetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, item kuwoSearchItem) {
			defer wg.Done()
			musicID := kuwoMusicID(item.MusicRID)
			if musicID == "" {
				return
			}
			lines, err := kuwoFetchLyric(ctx, musicID)
			if err != nil || len(lines) == 0 {
				return
			}
			lrc := kuwoBuildLRC(lines)
			if !isTimedLRC(lrc) {
				return
			}
			fetchedByRank[rank] = &fetched{lrc: lrc, it: item}
		}(i, c.item)
	}
	wg.Wait()

	for _, f := range fetchedByRank {
		if f == nil {
			continue
		}
		return kuwoResult{
			lyrics: f.lrc, title: f.it.SongName, artist: f.it.Artist, album: f.it.Album,
			durationSecs: kuwoDurationSecs(f.it.Duration), cover: kuwoCoverURL(f.it.WebAlbumPicShort),
		}
	}
	return kuwoResult{}
}
