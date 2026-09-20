package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

type lbClient struct {
	root    string
	token   string
	hc      *http.Client
	dryRun  bool
	alerter *alerter

	mu             sync.Mutex
	cooldownUntil  time.Time
	consecutive429 int
}

var lbCooldownSchedule = []time.Duration{
	30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute,
}

func (c *lbClient) coolingDown() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Before(c.cooldownUntil)
}

func (c *lbClient) noteOutcome(success bool, lastStatus int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if success {
		c.consecutive429 = 0
		c.cooldownUntil = time.Time{}
		return
	}
	if lastStatus != http.StatusTooManyRequests {

		return
	}
	c.consecutive429++
	idx := c.consecutive429 - 1
	if idx >= len(lbCooldownSchedule) {
		idx = len(lbCooldownSchedule) - 1
	}
	c.cooldownUntil = time.Now().Add(lbCooldownSchedule[idx])
}

type lbTrackMeta struct {
	ArtistName     string         `json:"artist_name"`
	TrackName      string         `json:"track_name"`
	ReleaseName    string         `json:"release_name,omitempty"`
	AdditionalInfo map[string]any `json:"additional_info,omitempty"`
}

func lbMeta(s snapshot) lbTrackMeta {
	info := map[string]any{
		"media_player":              mediaPlayerLabel(s.Bundle),
		"source":                    "mac",
		"submission_client":         clientName,
		"submission_client_version": clientVersion,
	}
	if s.Duration > 0 {
		info["duration_ms"] = int64(s.Duration * 1000)
	}

	if !s.AnchorTS.IsZero() {

		rate := s.Rate
		if s.Playing && rate == 0 {
			rate = 1
		} else if !s.Playing {
			rate = 0
		}
		info["progress_ms"] = int64(s.Position * 1000)
		info["progress_ts"] = s.AnchorTS.UnixMilli()
		info["playback_rate"] = rate
	}

	enr := trackEnrichment(context.Background(), s.Artist, s.Title, s.Album, s.Bundle, s.Duration, false, s.Radio)
	for _, k := range []string{"cover_url", "accent_color", "netease_url", "apple_music_url", "qq_music_url", "spotify_url", "cover_source", "lyrics_source"} {
		v := enr[k]
		if k == "cover_url" {

			v = webSafeCoverURL(v)
		}
		if v != "" {
			info[k] = v
		}
	}

	for k, v := range spotifyListenFields(s.Bundle, enr["spotify_track_id"]) {
		info[k] = v
	}

	budget := lyricBudgetBytes
	for _, k := range []string{"lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc"} {
		if v := enr[k]; v != "" && len(v) <= budget {
			info[k] = v
			budget -= len(v)
		}
	}

	return lbTrackMeta{
		ArtistName: s.Artist,
		TrackName:  s.Title,

		ReleaseName:    s.albumForUpload(),
		AdditionalInfo: info,
	}
}

var errListenRejected = errors.New("listen rejected by server (4xx, non-retryable)")

func (c *lbClient) submit(ctx context.Context, listenType string, listenedAt int64, meta lbTrackMeta) error {
	if listenType == "single" {

		for _, k := range []string{"lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc"} {
			delete(meta.AdditionalInfo, k)
		}
	}
	item := map[string]any{"track_metadata": meta}
	if listenType == "single" {
		item["listened_at"] = listenedAt
	}
	body, err := json.Marshal(map[string]any{
		"listen_type": listenType,
		"payload":     []any{item},
	})
	if err != nil {
		return fmt.Errorf("marshal %s: %w", listenType, err)
	}
	if c.dryRun {
		log.Printf("[dry-run] would POST %s: %s", listenType, body)
		return nil
	}
	if c.token == "" {

		return nil
	}
	if c.coolingDown() {

		return fmt.Errorf("post %s: skipped, ListenBrainz still cooling down after repeated 429", listenType)
	}

	tries, perTry := 1, playingNowTimeout
	if listenType == "single" {
		tries, perTry = singleMaxTries, singleTimeout
	}
	var lastErr error
	var lastStatus int
	for attempt := 0; attempt < tries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(500<<(attempt-1)) * time.Millisecond):
			}
		}
		status, err := c.submitOnce(ctx, body, perTry)
		if err == nil {
			c.noteOutcome(true, status)
			return nil
		}
		lastStatus = status
		if status >= 400 && status < 500 && status != http.StatusTooManyRequests {
			return fmt.Errorf("post %s: %v: %w", listenType, err, errListenRejected)
		}
		lastErr = fmt.Errorf("post %s: %w", listenType, err)
	}
	c.noteOutcome(false, lastStatus)
	return lastErr
}

func (c *lbClient) submitOnce(ctx context.Context, body []byte, timeout time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.root+"/1/submit-listens", bytes.NewReader(body))
	if err != nil {
		return 0, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Token "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return resp.StatusCode, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
	return http.StatusOK, nil
}
