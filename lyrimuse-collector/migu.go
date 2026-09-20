package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"encoding/json"
)

type miguResult struct {
	lyrics, tr, title, artist, album string

	cover string
}

var (
	miguMu    sync.Mutex
	miguCache = map[string]miguResult{}
)

func miguLyric(ctx context.Context, artist, title, album string, durationSecs float64) miguResult {
	if title == "" {
		return miguResult{}
	}
	key := artist + "|" + title + "|" + album
	miguMu.Lock()
	if v, ok := miguCache[key]; ok {
		miguMu.Unlock()
		return v
	}
	miguMu.Unlock()

	r := resolveMiguLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		miguMu.Lock()
		miguCache[key] = r
		miguMu.Unlock()
	}
	return r
}

type miguSearchItem struct {
	Name        string `json:"name"`
	CopyrightID string `json:"copyrightId"`
	LyricURL    string `json:"lyricUrl"`
	TrcURL      string `json:"trcUrl"`
	Singers     []struct {
		Name string `json:"name"`
	} `json:"singers"`
	Albums []struct {
		Name string `json:"name"`
	} `json:"albums"`
	ImgItems []struct {
		Img         string `json:"img"`
		ImgSizeType string `json:"imgSizeType"`
	} `json:"imgItems"`
}

func (it miguSearchItem) artistName() string {
	names := make([]string, 0, len(it.Singers))
	for _, s := range it.Singers {
		if n := strings.TrimSpace(s.Name); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, "/")
}

func (it miguSearchItem) albumName() string {
	if len(it.Albums) == 0 {
		return ""
	}
	return strings.TrimSpace(it.Albums[0].Name)
}

func miguCoverURL(it miguSearchItem) string {
	best := ""
	for _, img := range it.ImgItems {
		u := strings.TrimSpace(img.Img)
		if u == "" {
			continue
		}
		if img.ImgSizeType == "03" {
			return u
		}
		best = u
	}
	return best
}

func miguSearch(ctx context.Context, artist, title string) ([]miguSearchItem, error) {
	q := strings.TrimSpace(artist + " " + title)
	u := "https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do?text=" + neturl.QueryEscape(q) +
		"&pageNo=1&pageSize=10&searchSwitch=" + neturl.QueryEscape(`{"song":1}`) + "&isCorrect=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://m.music.migu.cn/")
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
		Code           string `json:"code"`
		SongResultData struct {
			Result []miguSearchItem `json:"result"`
		} `json:"songResultData"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != "" && out.Code != "000000" {
		return nil, fmt.Errorf("code %s", out.Code)
	}
	return out.SongResultData.Result, nil
}

func miguFetchLRC(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 512<<10))
	if err != nil {
		return "", err
	}
	return miguStripMetaLines(string(body)), nil
}

var miguMetaLineRe = regexp.MustCompile(`^(歌曲名|歌手名)(\s|[:：]|$)`)

func miguStripMetaLines(lrc string) string {
	lrc = strings.ReplaceAll(lrc, "\r\n", "\n")
	lrc = strings.ReplaceAll(lrc, "\r", "\n")
	var b strings.Builder
	for _, line := range strings.Split(lrc, "\n") {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || miguMetaLineRe.MatchString(text) {
			continue
		}
		b.WriteString(strings.TrimRight(line, " \t"))
		b.WriteString("\n")
	}
	return b.String()
}

func miguCandidateScore(item miguSearchItem, artist, title, album string) int {
	if strings.TrimSpace(item.LyricURL) == "" {
		return -1
	}
	if !lyricTitleAccepted(item.Name, title) {
		return -1
	}
	if !lyricSourceArtistMatches(item.artistName(), artist) {
		return -1
	}
	if versionTagsMismatch(title, album, item.Name, item.albumName()) {
		return -1
	}
	return 100
}

const miguMaxCandidatesToFetch = 3

func resolveMiguLyric(ctx context.Context, artist, title, album string, _ float64) miguResult {
	items, err := miguSearch(ctx, artist, title)
	if err != nil || len(items) == 0 {
		return miguResult{}
	}

	type scoredItem struct {
		item  miguSearchItem
		score int
	}
	var candidates []scoredItem
	for _, it := range items {
		if s := miguCandidateScore(it, artist, title, album); s >= 0 {
			candidates = append(candidates, scoredItem{it, s})
		}
	}
	if len(candidates) == 0 {
		return miguResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > miguMaxCandidatesToFetch {
		candidates = candidates[:miguMaxCandidatesToFetch]
	}

	fetchedByRank := make([]string, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, item miguSearchItem) {
			defer wg.Done()
			lrc, err := miguFetchLRC(ctx, item.LyricURL)
			if err != nil || !isTimedLRC(lrc) {
				return
			}
			fetchedByRank[rank] = lrc
		}(i, c.item)
	}
	wg.Wait()

	for rank, lrc := range fetchedByRank {
		if lrc == "" {
			continue
		}
		it := candidates[rank].item
		r := miguResult{
			lyrics: lrc, title: it.Name, artist: it.artistName(), album: it.albumName(),
			cover: miguCoverURL(it),
		}
		if u := strings.TrimSpace(it.TrcURL); u != "" {
			if tr, err := miguFetchLRC(ctx, u); err == nil && isTimedLRC(tr) {
				r.tr = tr
			}
		}
		return r
	}
	return miguResult{}
}
