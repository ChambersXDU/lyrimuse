package main

import (
	"log"
	"sync"
	"time"
)

const (

	staleAnchorAfterSecs = 2.0

	frozenAnchorPauseDropSecs = 3.0
)

func pausedPositionSecs(reported float64, anchorAge float64, hasAnchorAge bool,
	lastPlaying float64, hasLastPlaying bool) float64 {
	if !hasLastPlaying {
		return reported
	}
	if !hasAnchorAge || anchorAge <= staleAnchorAfterSecs {
		return reported
	}
	if lastPlaying-reported > frozenAnchorPauseDropSecs {
		return lastPlaying
	}
	return reported
}

func mediaControlAnchorAge(ts string, now time.Time) (float64, bool) {
	if ts == "" {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return 0, false
	}
	return now.Sub(t).Seconds(), true
}

var (
	playingPositionMu    sync.Mutex
	playingPositionTrack string
	playingPositionValue float64
	playingPositionKnown bool
)

func rememberedPlayingPosition(track string) (float64, bool) {
	playingPositionMu.Lock()
	defer playingPositionMu.Unlock()
	if !playingPositionKnown || playingPositionTrack != track {
		return 0, false
	}
	return playingPositionValue, true
}

func rememberPlayingPosition(track string, pos float64) {
	playingPositionMu.Lock()
	playingPositionTrack = track
	playingPositionValue = pos
	playingPositionKnown = true
	playingPositionMu.Unlock()
}

func playingPositionSecs(elapsedTime, elapsedTimeNow, rate float64, ts string, now time.Time) float64 {
	if rate > 0 {
		return elapsedTimeNow
	}
	if ts == "" {
		return elapsedTimeNow
	}
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return elapsedTimeNow
	}
	aged := now.Sub(t).Seconds() - 0.5
	if aged <= 0 {
		return elapsedTime
	}
	return elapsedTime + aged
}

type playingAnchor struct {
	track   string
	elapsed float64
	ts      string
	at      time.Time
}

var (
	playingAnchorMu        sync.Mutex
	lastPlayingAnchor      *playingAnchor
	lastIgnoredRepublishTS string
)

func isStaleAnchorRepublish(last *playingAnchor, track string, elapsed float64, ts string, duration float64, now time.Time) bool {
	if last == nil || ts == "" || last.track != track || last.elapsed != elapsed || elapsed <= 0 || last.ts == ts {
		return false
	}
	if duration > 0 && last.elapsed+now.Sub(last.at).Seconds() > duration+1 {
		return false
	}
	return true
}

func resolvePlayingAnchorTS(track string, elapsed float64, ts string, duration float64, now time.Time) (string, bool) {
	playingAnchorMu.Lock()
	defer playingAnchorMu.Unlock()
	if isStaleAnchorRepublish(lastPlayingAnchor, track, elapsed, ts, duration, now) {
		if lastIgnoredRepublishTS != ts {
			lastIgnoredRepublishTS = ts
			log.Printf("stale anchor republish ignored: elapsed=%.3f newTs=%s keepingAnchorTs=%s track=%q", elapsed, ts, lastPlayingAnchor.ts, track)
		}
		return lastPlayingAnchor.ts, true
	}
	at := now
	if t, err := time.Parse(time.RFC3339, ts); err == nil {
		at = t.Add(500 * time.Millisecond)
	}
	lastPlayingAnchor = &playingAnchor{track: track, elapsed: elapsed, ts: ts, at: at}
	lastIgnoredRepublishTS = ""
	return ts, false
}
