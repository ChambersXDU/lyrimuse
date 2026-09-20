package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type deezerResult struct {
	lyrics, title, artist, album string

	cover string

	durationSecs float64

	plainOnly bool
}

func (r deezerResult) empty() bool { return r.lyrics == "" }

const (
	deezerSearchAPI = "https://api.deezer.com/search"
	deezerAuthAPI   = "https://auth.deezer.com/login/anonymous?jo=p&rto=c&i=c"
	deezerPipeAPI   = "https://pipe.deezer.com/api"

	deezerScoreDurationTolerance = 0.25

	deezerMaxCandidatesToFetch = 3
	deezerHTTPTimeout          = 6 * time.Second

	deezerJWTFallbackTTL = time.Hour

	deezerJWTRenewMargin = 5 * time.Minute
)

const deezerLyricsQuery = `query SynchronizedTrackLyrics($trackId: String!) {
  track(trackId: $trackId) {
    id
    lyrics {
      id
      text
      synchronizedLines {
        lrcTimestamp
        line
      }
    }
  }
}`

var (
	deezerMu    sync.Mutex
	deezerCache = map[string]deezerResult{}

	deezerJWTMu       sync.Mutex
	deezerJWT         string
	deezerJWTExpires  time.Time
	deezerJWTFetchMu  sync.Mutex
	deezerLastFailMu  sync.Mutex
	deezerLastFailure string
)

func deezerSetLastFailureReason(reason string) {
	deezerLastFailMu.Lock()
	deezerLastFailure = reason
	deezerLastFailMu.Unlock()
}

func deezerLastFailureReasonNow() string {
	deezerLastFailMu.Lock()
	defer deezerLastFailMu.Unlock()
	return deezerLastFailure
}

func deezerLyric(ctx context.Context, artist, title, album string, durationSecs float64) deezerResult {
	if title == "" {
		return deezerResult{}
	}
	key := artist + "|" + title + "|" + album
	deezerMu.Lock()
	if v, ok := deezerCache[key]; ok {
		deezerMu.Unlock()
		return v
	}
	deezerMu.Unlock()

	r := resolveDeezerLyric(ctx, artist, title, album, durationSecs)
	if !r.empty() {
		deezerMu.Lock()
		deezerCache[key] = r
		deezerMu.Unlock()
	}
	return r
}

type deezerTrack struct {
	ID           int64  `json:"id"`
	Title        string `json:"title"`
	TitleVersion string `json:"title_version"`
	Duration     int    `json:"duration"`
	Artist       struct {
		Name string `json:"name"`
	} `json:"artist"`
	Album struct {
		Title   string `json:"title"`
		CoverXL string `json:"cover_xl"`
		CoverBg string `json:"cover_big"`
	} `json:"album"`
}

func (t deezerTrack) cover() string {
	if u := strings.TrimSpace(t.Album.CoverXL); u != "" {
		return u
	}
	return strings.TrimSpace(t.Album.CoverBg)
}

func deezerSearch(ctx context.Context, artist, title string) ([]deezerTrack, error) {
	q := strings.TrimSpace(artist + " " + title)
	u := deezerSearchAPI + "?limit=10&q=" + neturl.QueryEscape(q)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Data  []deezerTrack   `json:"data"`
		Error json.RawMessage `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&out); err != nil {
		return nil, err
	}

	if deezerHasError(out.Error) {
		return nil, fmt.Errorf("api error %s", strings.TrimSpace(string(out.Error)))
	}
	return out.Data, nil
}

func deezerHasError(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	return s != "" && s != "null" && s != "[]" && s != "{}"
}

func deezerCandidateScore(t deezerTrack, artist, title, album string, durationSecs float64) int {
	if t.ID <= 0 {
		return -1
	}
	if !lyricTitleAccepted(t.Title, title) {
		return -1
	}
	if !lyricSourceArtistMatches(t.Artist.Name, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, t.Title, t.Album.Title) {
		return -1
	}
	score := 100
	if durationSecs > 0 {
		d := float64(t.Duration)
		if d <= 0 {
			return score
		}
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > deezerScoreDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

func deezerJWTExpiry(jwt string) time.Time {
	parts := strings.Split(jwt, ".")
	if len(parts) < 2 {
		return time.Time{}
	}
	payload := parts[1]
	if pad := len(payload) % 4; pad != 0 {
		payload += strings.Repeat("=", 4-pad)
	}
	raw, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return time.Time{}
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(raw, &claims) != nil || claims.Exp <= 0 {
		return time.Time{}
	}
	return time.Unix(claims.Exp, 0)
}

func deezerEnsureJWT(ctx context.Context) string {
	now := time.Now()
	deezerJWTMu.Lock()
	tok, exp := deezerJWT, deezerJWTExpires
	deezerJWTMu.Unlock()
	if tok != "" && now.Before(exp) {
		return tok
	}
	deezerJWTFetchMu.Lock()
	defer deezerJWTFetchMu.Unlock()
	deezerJWTMu.Lock()
	tok, exp = deezerJWT, deezerJWTExpires
	deezerJWTMu.Unlock()
	if tok != "" && now.Before(exp) {
		return tok
	}
	tok = deezerFetchJWT(ctx)
	if tok == "" {
		return ""
	}
	exp = deezerJWTExpiry(tok)
	if exp.IsZero() {
		exp = time.Now().Add(deezerJWTFallbackTTL)
	} else {
		exp = exp.Add(-deezerJWTRenewMargin)
	}
	deezerJWTMu.Lock()
	deezerJWT, deezerJWTExpires = tok, exp
	deezerJWTMu.Unlock()
	return tok
}

func deezerClearJWT() {
	deezerJWTMu.Lock()
	deezerJWT, deezerJWTExpires = "", time.Time{}
	deezerJWTMu.Unlock()
}

func deezerFetchJWT(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, deezerAuthAPI, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
	if err != nil {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	var out struct {
		JWT string `json:"jwt"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	if strings.TrimSpace(out.JWT) == "" {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	return strings.TrimSpace(out.JWT)
}

type deezerSyncLine struct {
	LRCTimestamp string `json:"lrcTimestamp"`
	Line         string `json:"line"`
}

func deezerBuildLRC(lines []deezerSyncLine) string {
	var b strings.Builder
	for _, l := range lines {
		ts := strings.TrimSpace(l.LRCTimestamp)
		text := strings.TrimSpace(l.Line)
		if ts == "" || text == "" {
			continue
		}
		b.WriteString(ts)
		b.WriteString(text)
		b.WriteString("\n")
	}
	return b.String()
}

func deezerIsLyricsNotFound(errs string) bool {
	return strings.Contains(errs, "LyricsNotFoundError") || strings.Contains(errs, "Lyrics does not exists")
}

func deezerFetchLyrics(ctx context.Context, trackID string) (string, string, error) {
	for attempt := 0; attempt < 2; attempt++ {
		jwt := deezerEnsureJWT(ctx)
		if jwt == "" {
			return "", "", fmt.Errorf("no anonymous jwt")
		}
		body, err := json.Marshal(map[string]any{
			"operationName": "SynchronizedTrackLyrics",
			"variables":     map[string]any{"trackId": trackID},
			"query":         deezerLyricsQuery,
		})
		if err != nil {
			return "", "", err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, deezerPipeAPI, strings.NewReader(string(body)))
		if err != nil {
			return "", "", err
		}
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+jwt)
		resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
		if err != nil {
			return "", "", err
		}
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		status := resp.StatusCode
		resp.Body.Close()
		if status == http.StatusUnauthorized && attempt == 0 {
			deezerClearJWT()
			continue
		}
		if status != http.StatusOK {
			return "", "", fmt.Errorf("status %d", status)
		}
		if readErr != nil {
			return "", "", readErr
		}
		var out struct {
			Errors json.RawMessage `json:"errors"`
			Data   struct {
				Track struct {
					Lyrics struct {
						Text              string           `json:"text"`
						SynchronizedLines []deezerSyncLine `json:"synchronizedLines"`
					} `json:"lyrics"`
				} `json:"track"`
			} `json:"data"`
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			return "", "", err
		}
		if deezerHasError(out.Errors) {
			errs := string(out.Errors)
			if deezerIsLyricsNotFound(errs) {

				return "", "", nil
			}
			return "", "", fmt.Errorf("graphql error %s", strings.TrimSpace(errs))
		}
		ly := out.Data.Track.Lyrics
		return deezerBuildLRC(ly.SynchronizedLines), strings.TrimSpace(ly.Text), nil
	}
	return "", "", fmt.Errorf("jwt refresh exhausted")
}

func resolveDeezerLyric(ctx context.Context, artist, title, album string, durationSecs float64) deezerResult {
	tracks, err := deezerSearch(ctx, artist, title)
	if err != nil || len(tracks) == 0 {
		return deezerResult{}
	}

	type scoredTrack struct {
		track deezerTrack
		score int
	}
	var candidates []scoredTrack
	for _, t := range tracks {
		if s := deezerCandidateScore(t, artist, title, album, durationSecs); s >= 0 {
			candidates = append(candidates, scoredTrack{t, s})
		}
	}
	if len(candidates) == 0 {
		return deezerResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > deezerMaxCandidatesToFetch {
		candidates = candidates[:deezerMaxCandidatesToFetch]
	}

	type fetched struct{ synced, plain string }
	got := make([]fetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, t deezerTrack) {
			defer wg.Done()
			synced, plain, err := deezerFetchLyrics(ctx, strconv.FormatInt(t.ID, 10))
			if err != nil {
				return
			}
			if isTimedLRC(synced) {
				got[rank] = fetched{synced: synced}
				return
			}
			got[rank] = fetched{plain: plain}
		}(i, c.track)
	}
	wg.Wait()

	build := func(rank int, lyrics string, plainOnly bool) deezerResult {
		t := candidates[rank].track
		return deezerResult{
			lyrics: lyrics, title: t.Title, artist: t.Artist.Name, album: t.Album.Title,
			cover: t.cover(), durationSecs: float64(t.Duration), plainOnly: plainOnly,
		}
	}
	for rank, f := range got {
		if f.synced != "" {
			return build(rank, f.synced, false)
		}
	}
	for rank, f := range got {
		if f.plain != "" {
			return build(rank, f.plain, true)
		}
	}
	return deezerResult{}
}
