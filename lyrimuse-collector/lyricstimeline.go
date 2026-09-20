package main

import (
	"log"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

type yrcLineHead struct {
	ms   int
	text string
}

func yrcLineHeads(yrc string) []yrcLineHead {
	if yrc == "" {
		return nil
	}
	var out []yrcLineHead
	for _, line := range strings.Split(yrc, "\n") {
		m := yrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		ms, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		body := yrcLineTimeRegex.ReplaceAllString(line, "")
		text := strings.TrimSpace(yrcWordTokenRe.ReplaceAllString(body, ""))
		if text == "" {
			continue
		}
		out = append(out, yrcLineHead{ms: ms, text: text})
	}
	return out
}

func normTimelineText(s string) string {
	s = toSimplified(strings.ToLower(s))
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func lrcStampMs(m []string) int {
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac, _ := strconv.Atoi(m[3])
	ms := (mm*60 + ss) * 1000
	switch len(m[3]) {
	case 3:
		ms += frac
	default:
		ms += frac * 10
	}
	return ms
}

func formatLRCStamp(ms int) string {
	if ms < 0 {
		ms = 0
	}
	return "[" + twoDigits(ms/60000) + ":" + twoDigits((ms%60000)/1000) + "." + twoDigits((ms%1000)/10) + "]"
}

func twoDigits(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

func rehangLRCOnYRC(lrc, yrc string, durationSecs float64, guard bool) (string, map[int]int, bool) {
	heads := yrcLineHeads(yrc)
	if lrc == "" || len(heads) < 2 {
		return lrc, nil, false
	}
	for i := 1; i < len(heads); i++ {
		if heads[i].ms < heads[i-1].ms {
			return lrc, nil, false
		}
	}
	lines := strings.Split(lrc, "\n")
	var idxs []int
	var texts []string
	var oldMs []int
	for i, line := range lines {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) == 0 {
			continue
		}
		if len(stamps) > 1 {
			return lrc, nil, false
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		idxs = append(idxs, i)
		texts = append(texts, text)
		oldMs = append(oldMs, lrcStampMs(stamps[0]))
	}
	if len(idxs) < 2 || len(idxs) != len(heads) {
		return lrc, nil, false
	}
	for i := range texts {
		if normTimelineText(texts[i]) != normTimelineText(heads[i].text) {
			return lrc, nil, false
		}
	}

	const stampQuantMs = 10
	changed := false
	for i := range oldMs {
		d := oldMs[i] - heads[i].ms
		if d < 0 {
			d = -d
		}
		if d > stampQuantMs {
			changed = true
			break
		}
	}
	if !changed {
		return lrc, nil, false
	}

	out := make([]string, len(lines))
	copy(out, lines)
	remap := make(map[int]int, len(idxs))
	for k, i := range idxs {
		out[i] = formatLRCStamp(heads[k].ms) + texts[k]
		remap[oldMs[k]] = heads[k].ms
	}
	newLRC := strings.Join(out, "\n")

	if newLRC == lrc {
		return lrc, nil, false
	}
	if guard {

		if durationSecs <= 0 {
			return lrc, nil, false
		}
		oldLast, okOld := lastLRCTimestampSecs(lrc)
		newLast, okNew := lastLRCTimestampSecs(newLRC)
		if okOld && okNew && durationFits(oldLast, durationSecs) && !durationFits(newLast, durationSecs) {
			return lrc, nil, false
		}
	}
	return newLRC, remap, true
}

const (
	wordTimingContradictionSkewMs     = 10000
	wordTimingContradictionMinMatched = 8
)

func timelineLCSAlign(tn, hn []string) []int {
	n, m := len(tn), len(hn)
	dp := make([][]int32, n+1)
	for i := range dp {
		dp[i] = make([]int32, m+1)
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			if tn[i-1] == hn[j-1] && tn[i-1] != "" {
				dp[i][j] = dp[i-1][j-1] + 1
			} else if dp[i-1][j] >= dp[i][j-1] {
				dp[i][j] = dp[i-1][j]
			} else {
				dp[i][j] = dp[i][j-1]
			}
		}
	}
	align := make([]int, n)
	for i := range align {
		align[i] = -1
	}
	i, j := n, m
	for i > 0 && j > 0 {
		if tn[i-1] == hn[j-1] && tn[i-1] != "" && dp[i][j] == dp[i-1][j-1]+1 {
			align[i-1] = j - 1
			i--
			j--
		} else if dp[i-1][j] >= dp[i][j-1] {
			i--
		} else {
			j--
		}
	}
	return align
}

func wordTimingContradictsLRC(lrc, yrc string) bool {
	heads := yrcLineHeads(yrc)
	if len(heads) < 2 {
		return false
	}
	var texts []string
	var oldMs []int
	for _, line := range strings.Split(lrc, "\n") {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) != 1 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		texts = append(texts, text)
		oldMs = append(oldMs, lrcStampMs(stamps[0]))
	}
	if len(texts) < 2 {
		return false
	}
	tn := make([]string, len(texts))
	for i, s := range texts {
		tn[i] = normTimelineText(s)
	}
	hn := make([]string, len(heads))
	for i, h := range heads {
		hn[i] = normTimelineText(h.text)
	}
	align := timelineLCSAlign(tn, hn)
	var diffs []int
	for i, a := range align {
		if a < 0 {
			continue
		}
		d := oldMs[i] - heads[a].ms
		if d < 0 {
			d = -d
		}
		diffs = append(diffs, d)
	}
	if len(diffs) < wordTimingContradictionMinMatched || len(diffs)*2 < len(texts) {
		return false
	}
	sort.Ints(diffs)
	return diffs[len(diffs)/2] >= wordTimingContradictionSkewMs
}

func remapLRCTimestamps(lrc string, remap map[int]int) (string, bool) {
	if lrc == "" || len(remap) == 0 {
		return lrc, false
	}
	lines := strings.Split(lrc, "\n")
	changed := false
	for i, line := range lines {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) != 1 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		newMs, ok := remap[lrcStampMs(stamps[0])]
		if !ok {
			continue
		}
		lines[i] = formatLRCStamp(newMs) + text
		changed = true
	}
	if !changed {
		return lrc, false
	}
	return strings.Join(lines, "\n"), true
}

func rehangCandidateTimelines(candidates []lyricCandidate, durationSecs float64) {
	for i := range candidates {
		fixed, remap, ok := rehangLRCOnYRC(candidates[i].lyrics, candidates[i].wordTimingYRC, durationSecs, true)
		if ok {
			candidates[i].lyrics = fixed
			candidates[i].timelineRemap = remap
			continue
		}
		if candidates[i].wordTimingYRC != "" && wordTimingContradictsLRC(candidates[i].lyrics, candidates[i].wordTimingYRC) {
			candidates[i].wordTimingYRC = ""
			candidates[i].hasWordTiming = false
		}
	}
}

func migrateLyricTimelines() {
	enrichMu.Lock()
	fixed := 0
	dropped := 0
	for k, e := range enrichCache {
		if e.ManualLyrics {
			continue
		}
		dur := e.DurationSecs
		if dur <= 0 {
			dur = e.ResolvedDurationSecs
		}
		newLyrics, remap, ok := rehangLRCOnYRC(e.Lyrics, e.LyricsYRC, dur, true)
		if !ok {

			if e.LyricsYRC != "" && wordTimingContradictsLRC(e.Lyrics, e.LyricsYRC) {
				e.LyricsYRC = ""
				enrichCache[k] = e
				dropped++
			}
			continue
		}
		e.Lyrics = newLyrics
		if tr, ok2 := remapLRCTimestamps(e.LyricsTr, remap); ok2 {
			e.LyricsTr = tr
		}
		if roma, ok2 := remapLRCTimestamps(e.LyricsRoma, remap); ok2 {
			e.LyricsRoma = roma
		}
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 || dropped > 0 {

		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 || dropped > 0 {
		log.Printf("lyric timeline migration: rehung %d entries, dropped contradictory word timing in %d entries", fixed, dropped)
		saveEnrichCache()
	}
}
