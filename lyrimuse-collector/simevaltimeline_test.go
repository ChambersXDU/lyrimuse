package main

import (
	"math"
	"sort"
)

func timelineSkewMedian(lrc, yrc string, minPairs int) (median float64, pairs int, ok bool) {
	le := lrcEventsOf(lrc)
	ye := yrcLineHeads(yrc)
	if len(le) < minPairs || len(ye) < minPairs {
		return 0, 0, false
	}
	lby := map[string][]int{}
	for _, e := range le {
		if n := normTimelineText(e.text); n != "" {
			lby[n] = append(lby[n], e.ms)
		}
	}
	yby := map[string][]int{}
	for _, e := range ye {
		if n := normTimelineText(e.text); n != "" {
			yby[n] = append(yby[n], e.ms)
		}
	}
	var diffs []float64
	for n, lts := range lby {
		yts := yby[n]
		if len(lts) != 1 || len(yts) != 1 {
			continue
		}
		diffs = append(diffs, math.Abs(float64(lts[0]-yts[0]))/1000)
	}
	if len(diffs) < minPairs {
		return 0, len(diffs), false
	}
	sort.Float64s(diffs)
	mid := len(diffs) / 2
	if len(diffs)%2 == 1 {
		return diffs[mid], len(diffs), true
	}
	return (diffs[mid-1] + diffs[mid]) / 2, len(diffs), true
}

func wordTimingPointsOf(ec *evalCand) int {
	return scoreTermPoints(ec.v2Terms, scoreTermWordTiming)
}

func deltaTimelineEndpointGate(thresholdSecs float64) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		wt := wordTimingPointsOf(ec)
		if wt <= 0 || ec.c.wordTimingYRC == "" || !ec.hasLast {
			return 0
		}
		st := parseYRCStats(ec.c.wordTimingYRC)
		if st.lastLineStartMs == 0 {
			return 0
		}
		if math.Abs(float64(st.lastLineStartMs)/1000-ec.last) > thresholdSecs {
			return -wt
		}
		return 0
	}
}

func deltaTimelineSkewGate(thresholdSecs float64) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		wt := wordTimingPointsOf(ec)
		if wt <= 0 || ec.c.wordTimingYRC == "" {
			return 0
		}
		med, _, ok := timelineSkewMedian(ec.c.lyrics, ec.c.wordTimingYRC, 4)
		if !ok {
			return 0
		}
		if med > thresholdSecs {
			return -wt
		}
		return 0
	}
}

func deltaRichsyncLRCAt(guarded bool) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		if ec.c.wordTimingYRC == "" {
			return 0
		}
		newLyrics, _, ok := rehangLRCOnYRC(ec.c.lyrics, ec.c.wordTimingYRC, tr.dur, guarded)
		if !ok {
			return 0
		}

		batch := make([]lyricCandidate, len(tr.cands))
		for j := range tr.cands {
			batch[j] = tr.cands[j].c
		}
		batch[i].lyrics = newLyrics
		corro := corroboratedEndings(batch, tr.dur)
		peers := contentConsensusPeers(tr.la, tr.lt, batch, tr.dur)
		_, terms := scoreLyricCandidateDetailed(tr.la, tr.lt, tr.lal, tr.dur, batch[i], corro[batch[i].source], len(peers[batch[i].source]))
		newRaw := 0
		for _, t := range terms {
			newRaw += t.Points
		}
		return newRaw - ec.rawSum
	}
}
