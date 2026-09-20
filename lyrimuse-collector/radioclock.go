package main

import (
	"sync"
	"time"
)

const radioMaxAdvancePerTick = 30 * time.Second

type radioClockState struct {
	trackKey string
	position float64
	tickedAt time.Time

	playing bool
}

func advanceRadioClock(prev radioClockState, key string, playing bool, now time.Time) radioClockState {
	if prev.trackKey != key || prev.tickedAt.IsZero() {
		return radioClockState{trackKey: key, position: 0, tickedAt: now, playing: playing}
	}
	if !prev.playing {
		return radioClockState{trackKey: key, position: prev.position, tickedAt: now, playing: playing}
	}
	step := now.Sub(prev.tickedAt)
	if step < 0 {
		step = 0
	}
	if step > radioMaxAdvancePerTick {
		step = radioMaxAdvancePerTick
	}
	return radioClockState{trackKey: key, position: prev.position + step.Seconds(), tickedAt: now, playing: playing}
}

var (
	radioClockMu    sync.Mutex
	radioClockValue radioClockState
)

func applyRadioClock(s *snapshot, now time.Time) {
	if s == nil || !s.Radio {
		return
	}
	radioClockMu.Lock()
	next := advanceRadioClock(radioClockValue, s.key(), s.Playing, now)
	radioClockValue = next
	radioClockMu.Unlock()
	s.Elapsed, s.AnchorElapsed, s.McTS = next.position, next.position, now
}
