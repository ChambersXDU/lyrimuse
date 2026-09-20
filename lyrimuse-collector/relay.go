package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"strings"
	"time"
)

func relayState(s snapshot, playing bool, device string, listenedAt int64, current bool) map[string]any {
	meta := lbMeta(s)
	ai := meta.AdditionalInfo
	if device == "" {
		if v, _ := ai["source"].(string); v != "" {
			device = v
		}
	}

	enr := trackEnrichment(context.Background(), s.Artist, s.Title, s.Album, s.Bundle, s.Duration, false, s.Radio)
	st := map[string]any{
		"ok": true, "playing": playing, "current": current,

		"title": meta.TrackName, "artist": meta.ArtistName, "album": meta.ReleaseName,

		"artwork": ai["cover_url"], "accent": ai["accent_color"], "device": device,
		"lyrics": enr["lyrics"], "lyricsTr": enr["lyrics_tr"], "lyricsRoma": enr["lyrics_roma"], "lyricsYRC": enr["lyrics_yrc"],

		"coverSource": ai["cover_source"], "lyricsSource": ai["lyrics_source"],

		"mediaPlayer": ai["media_player"],
		"links":       map[string]any{"apple": ai["apple_music_url"], "qq": ai["qq_music_url"], "netease": ai["netease_url"], "spotify": ai["spotify_url"]},
		"durationMs":  ai["duration_ms"], "progressMs": ai["progress_ms"], "progressTs": ai["progress_ts"], "rate": ai["playback_rate"],
	}
	if listenedAt > 0 {
		st["listenedAt"] = listenedAt
	}
	return st
}

func postRelay(ctx context.Context, cfg *config, path string, payload any) error {
	if cfg.StateRelayURL == "" {
		return nil
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(cfg.StateRelayURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-token", cfg.StateRelayToken)
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("relay %s: status %d", path, resp.StatusCode)
	}
	return nil
}
