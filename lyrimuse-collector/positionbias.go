package main

import (
	"encoding/json"
	"log"
	"math"
	"os"
	"sync"
	"time"
)

type positionBiasRecord struct {
	Artist        string   `json:"artist"`
	Title         string   `json:"title"`
	BundleID      string   `json:"bundle_id"`
	AnchorElapsed *float64 `json:"anchor_elapsed"`
	BiasSecs      float64  `json:"bias_secs"`
	WrittenAtMs   int64    `json:"written_at_ms"`
}

const (

	positionBiasAnchorToleranceSecs = 0.001

	positionBiasAnchorSlack = time.Second

	positionBiasMaxAge = 6 * time.Hour
)

var (
	positionBiasPath string
	positionBiasMu   sync.Mutex

	positionBiasLastLoggedKey  string
	positionBiasLastLoggedBias float64
)

func setPositionBiasPath(path string) {
	positionBiasPath = path
}

func readPositionBiasRecord(path string) (positionBiasRecord, bool) {
	var rec positionBiasRecord
	if path == "" {
		return rec, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return rec, false
	}
	if err := json.Unmarshal(data, &rec); err != nil {
		return rec, false
	}
	return rec, true
}

func positionBiasApplies(rec positionBiasRecord, artist, title, bundleID string, anchorElapsed float64, anchorTS, now time.Time) bool {
	if rec.BiasSecs == 0 || rec.AnchorElapsed == nil {
		return false
	}
	if rec.BundleID != bundleID || rec.Artist != artist || rec.Title != title {
		return false
	}
	if math.Abs(*rec.AnchorElapsed-anchorElapsed) > positionBiasAnchorToleranceSecs {
		return false
	}
	if anchorTS.IsZero() {
		return false
	}
	written := time.UnixMilli(rec.WrittenAtMs)
	if written.Before(anchorTS.Add(-positionBiasAnchorSlack)) {
		return false
	}
	if now.Sub(written) > positionBiasMaxAge || written.After(now.Add(positionBiasAnchorSlack)) {
		return false
	}
	return true
}

func currentPositionBias(artist, title, bundleID string, anchorElapsed float64, anchorTSString string, now time.Time) (float64, bool) {
	rec, ok := readPositionBiasRecord(positionBiasPath)
	if !ok {
		return 0, false
	}
	var anchorTS time.Time
	if anchorTSString != "" {
		if t, err := time.Parse(time.RFC3339, anchorTSString); err == nil {
			anchorTS = t
		}
	}
	if !positionBiasApplies(rec, artist, title, bundleID, anchorElapsed, anchorTS, now) {
		return 0, false
	}
	key := artist + "|" + title
	positionBiasMu.Lock()
	changed := key != positionBiasLastLoggedKey || rec.BiasSecs != positionBiasLastLoggedBias
	if changed {
		positionBiasLastLoggedKey, positionBiasLastLoggedBias = key, rec.BiasSecs
	}
	positionBiasMu.Unlock()
	if changed {
		log.Printf("position bias from app: %+.3fs applied to %q (anchor elapsed %.3f)", -rec.BiasSecs, key, anchorElapsed)
	}
	return rec.BiasSecs, true
}
