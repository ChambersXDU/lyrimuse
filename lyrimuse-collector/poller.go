package main

import (
	"context"
	"log"
	"math"
	"time"
)

type poller struct {
	ctx context.Context

	cur          snapshot
	trackKey     string
	trackPos     float64
	prevWall     time.Time
	prevElapse   float64
	prevPlaying  bool
	prevDuration float64

	snapshotStale bool
	nullStreak    int
}

func (p *poller) isTracked() bool {
	return p.cur.Bundle == appleMusicBundleID && p.cur.key() != ""
}

func seedPosition(elapsed, rate float64, playing bool, mcTS, now time.Time) float64 {
	position := elapsed
	if !playing {
		return position
	}
	if rate <= 0 {
		rate = 1
	}
	if !mcTS.IsZero() {
		if age := now.Sub(mcTS).Seconds(); age > 0 {
			position += age * rate
		}
	}
	return position
}

func (p *poller) albumHintFor(s snapshot) string {
	if s.Album != "" || s.Title == "" || s.Artist == "" {
		return ""
	}
	return appleAlbumHint(p.ctx, s.Artist, s.Title, s.Duration, lyricResolvedArtists(s.Artist, s.Title, s.Album))
}

func (p *poller) updatePosition(now time.Time) {
	key := p.cur.key()
	if key == "" {
		p.trackKey = ""
		p.trackPos = 0
		p.prevWall = now
		p.cur.Position, p.cur.AnchorTS = 0, now
		return
	}

	gap := now.Sub(p.prevWall).Seconds()
	if gap < 0 || gap > 15 {
		gap = 0
	}
	rate := p.cur.Rate
	if rate <= 0 {
		rate = 1
	}
	seed := seedPosition(p.cur.Elapsed, p.cur.Rate, p.cur.Playing, p.cur.McTS, now)

	switch {
	case key != p.trackKey:
		p.trackPos = seed
	case p.snapshotStale:
		if p.cur.Playing {
			p.trackPos += gap * rate
		}
	case !p.cur.Playing:
		p.trackPos = p.cur.Elapsed
	case p.prevWall.IsZero(), math.Abs(p.cur.Elapsed-(p.prevElapse+gap*rate)) > 2:
		p.trackPos = seed
	default:
		p.trackPos += gap * rate
	}

	if p.cur.Duration > 0 {
		p.trackPos = min(max(p.trackPos, 0), p.cur.Duration)
	} else if p.trackPos < 0 {
		p.trackPos = 0
	}
	p.trackKey = key
	p.prevElapse = p.cur.Elapsed
	p.prevPlaying = p.cur.Playing
	p.prevDuration = p.cur.Duration
	p.prevWall = now
	p.cur.Position, p.cur.AnchorTS = p.trackPos, now
}

func (p *poller) enrichCurrent(isNewTrack bool) {
	if !p.isTracked() {
		return
	}
	trackEnrichment(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)
	if isNewTrack && features.AlbumPrefetch {
		prefetchAlbumSiblings(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, appleMusicBundleID)
	}
}

func (p *poller) poll() {
	oldKey := p.cur.key()
	p.snapshotStale = true
	if state, ok := getState(p.ctx); ok {
		if len(state) == 0 {
			p.nullStreak++
			if p.nullStreak >= 3 {
				p.cur = snapshot{}
				p.snapshotStale = false
			}
		} else {
			p.nullStreak = 0
			p.cur = extract(state)
			p.cur.AlbumHint = p.albumHintFor(p.cur)
			p.snapshotStale = false
		}
	}
	now := time.Now()
	p.updatePosition(now)
	if key := p.cur.key(); key != "" && key != oldKey {
		log.Printf("now playing: %s - %s", p.cur.Artist, p.cur.Title)
		p.enrichCurrent(true)
	} else if key != "" {
		p.enrichCurrent(false)
	}
}

func run(ctx context.Context, _ *config) error {
	p := &poller{ctx: ctx}
	enrichNotify = make(chan struct{}, 1)
	p.poll()
	go startEnrichCancelWatcher(ctx)
	go startLyricsFillSweeper(ctx)

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-enrichNotify:
			p.poll()
		case <-ticker.C:
			p.poll()
		}
	}
}
