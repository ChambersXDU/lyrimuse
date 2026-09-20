package main

import (
	"testing"
	"time"
)

func TestAdvanceRadioClock(t *testing.T) {
	base := time.Date(2026, 9, 10, 7, 15, 35, 0, time.UTC)

	s := advanceRadioClock(radioClockState{}, "Daniel Caesar|Who Knows", true, base)
	if s.position != 0 || s.trackKey != "Daniel Caesar|Who Knows" {
		t.Fatalf("first sight should start at 0, got %+v", s)
	}

	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(5*time.Second))
	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(10*time.Second))
	if s.position != 10 {
		t.Fatalf("playing should accumulate wall clock, got %.3f want 10", s.position)
	}

	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(11*time.Second))
	if s.position != 0 || s.trackKey != "Clairo|Juna" {
		t.Fatalf("track change must reset to 0, got %+v", s)
	}

	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(21*time.Second))
	if s.position != 10 {
		t.Fatalf("want 10 before pause, got %.3f", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", false, base.Add(23*time.Second))
	if s.position != 12 {
		t.Fatalf("the interval that ended in a pause was still mostly playing, got %.3f want 12", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", false, base.Add(120*time.Second))
	if s.position != 12 {
		t.Fatalf("pause must freeze the position, got %.3f", s.position)
	}

	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(125*time.Second))
	if s.position != 12 {
		t.Fatalf("resume must not count the paused span, got %.3f want 12", s.position)
	}

	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(128*time.Second))
	if s.position != 15 {
		t.Fatalf("after resuming the clock should run again, got %.3f want 15", s.position)
	}

	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(128*time.Second+2*time.Hour))
	if s.position != 15+radioMaxAdvancePerTick.Seconds() {
		t.Fatalf("a huge gap must be clamped, got %.3f", s.position)
	}

	before := s.position
	s = advanceRadioClock(s, "Clairo|Juna", true, base)
	if s.position != before {
		t.Fatalf("a backwards clock must not move the position, got %.3f want %.3f", s.position, before)
	}
}

func TestApplyRadioClockOnlyTouchesRadio(t *testing.T) {
	radioClockMu.Lock()
	saved := radioClockValue
	radioClockValue = radioClockState{}
	radioClockMu.Unlock()
	defer func() {
		radioClockMu.Lock()
		radioClockValue = saved
		radioClockMu.Unlock()
	}()

	now := time.Date(2026, 9, 10, 7, 20, 39, 0, time.UTC)
	normal := snapshot{Title: "Fushigi", Artist: "星野源", Elapsed: 42, AnchorElapsed: 7, Duration: 292.21, Playing: true}
	before := normal
	applyRadioClock(&normal, now)
	if normal != before {
		t.Fatalf("a non-radio snapshot must be left alone: %+v vs %+v", normal, before)
	}

	radio := snapshot{Title: "Juna", Artist: "Clairo", Elapsed: 467, AnchorElapsed: 0, Playing: true, Radio: true}
	applyRadioClock(&radio, now)
	if radio.Elapsed != 0 || radio.AnchorElapsed != 0 {
		t.Fatalf("first radio tick should anchor at 0, got elapsed=%.3f anchor=%.3f", radio.Elapsed, radio.AnchorElapsed)
	}
	if !radio.McTS.Equal(now) {
		t.Fatalf("McTS should be the tick instant, got %v", radio.McTS)
	}
	radio.Elapsed = 999
	applyRadioClock(&radio, now.Add(20*time.Second))
	if radio.Elapsed != 20 {
		t.Fatalf("radio position must come from our own clock, got %.3f want 20", radio.Elapsed)
	}
}

func TestExtractRadioDuration(t *testing.T) {
	radioState := map[string]any{
		"title": "Juna", "artist": "Clairo", "bundleIdentifier": "com.apple.Music",
		"duration": 3390.122, "elapsedTime": 467.0, "playing": true,
		"radioStationHash": "CgkIBRoFwOSKqxkQBA",
	}
	s := extract(radioState)
	if !s.Radio {
		t.Fatal("radioStationHash present → Radio must be true")
	}
	if s.Duration != 0 {
		t.Fatalf("no catalog duration → radio duration must be unknown (0), got %.3f", s.Duration)
	}

	radioState["catalogDurationSecs"] = 226.283
	if got := extract(radioState).Duration; got != 226.283 {
		t.Fatalf("radio duration should come from the Apple catalog, got %.3f want 226.283", got)
	}
	normalState := map[string]any{
		"title": "Fushigi", "artist": "星野源", "bundleIdentifier": "com.apple.Music",
		"duration": 292.21, "elapsedTime": 12.0, "playing": true,
	}
	n := extract(normalState)
	if n.Radio || n.Duration != 292.21 {
		t.Fatalf("normal playback must keep its duration, got radio=%v duration=%.3f", n.Radio, n.Duration)
	}
}

func TestMergeRadioKeys(t *testing.T) {

	state := map[string]any{"title": "Juna", "artist": "Clairo", "duration": 3390.1220703125}
	mergeRadioKeys(state, map[string]any{
		"radioStationHash": "CgkIBRoFwOSKqxkQBA", "catalogDurationSecs": 226.283,
	})
	if state["radioStationHash"] != "CgkIBRoFwOSKqxkQBA" {
		t.Errorf("电台判据没补上:%v", state["radioStationHash"])
	}
	if state["catalogDurationSecs"] != 226.283 {
		t.Errorf("目录曲长没补上:%v", state["catalogDurationSecs"])
	}
	if state["duration"] != 3390.1220703125 {
		t.Errorf("duration 该原样留着(换算在 snapshot.extract 里做),得到 %v", state["duration"])
	}

	state = map[string]any{"title": "Juna", "duration": 3390.122}
	mergeRadioKeys(state, map[string]any{"radioStationHash": "CgkIBRoFwOSKqxkQBA", "catalogDurationSecs": 0.0})
	if state["radioStationHash"] != "CgkIBRoFwOSKqxkQBA" {
		t.Errorf("目录没到位也该补判据,得到 %v", state["radioStationHash"])
	}
	if _, ok := state["catalogDurationSecs"]; ok {
		t.Errorf("目录曲长为 0 时不该写进 state,得到 %v", state["catalogDurationSecs"])
	}

	state = map[string]any{"title": "Fushigi", "duration": 289.7659912109375}
	mergeRadioKeys(state, map[string]any{"radioStationHash": "", "catalogDurationSecs": 289.766})
	if len(state) != 2 || state["duration"] != 289.7659912109375 {
		t.Errorf("非电台不该动 state,得到 %v", state)
	}
}

func TestBorrowAppleScriptPosition(t *testing.T) {
	const am = appleMusicBundleID
	cases := []struct {
		name                            string
		selected                        bool
		bundle                          string
		playing, tracked, radio, expect bool
	}{
		{"普通 Apple Music 播放:借", true, am, true, true, false, true},
		{"电台:不借 —— player position 报的是整档节目", true, am, true, true, true, false},
		{"没勾 Apple Music:不借", false, am, true, true, false, false},
		{"这一轮报的是别的播放器:不借(别拿 Music.app 的位置盖掉它算对的值)", true, spotifyBundleID, true, true, false, false},
		{"没在播:不借(位置本来就冻结,精度没有意义)", true, am, false, true, false, false},
		{"不是我们关心的来源:不借", true, am, true, false, false, false},
		{"电台 + 其它条件全满足也不借 —— 这条闸不能被别的条件绕过", true, am, true, true, true, false},
	}
	for _, c := range cases {
		if got := borrowAppleScriptPosition(c.selected, c.bundle, c.playing, c.tracked, c.radio); got != c.expect {
			t.Errorf("%s: borrowAppleScriptPosition(%v, %q, %v, %v, %v) = %v, 期望 %v",
				c.name, c.selected, c.bundle, c.playing, c.tracked, c.radio, got, c.expect)
		}
	}
}

func TestNeedsRadioDurationBackfill(t *testing.T) {
	cases := []struct {
		name             string
		sameTrack, radio bool
		sessDur, curDur  float64
		expect           bool
	}{
		{"电台 + 会话还没有曲长 + 目录已到位:补", true, true, 0, 150.447, true},
		{"目录还没到位(仍是 0):不补 —— 别把「未知」当成事实钉死一整首歌", true, true, 0, 0, false},
		{"会话已经有权威曲长:不覆盖", true, true, 150.447, 226.283, false},
		{"不是电台:不补 —— 换曲预载窗口里 duration 可能是下一首的脏值", true, false, 0, 226.283, false},
		{"换歌了:不补 —— 那是上一首的会话,补过去就是张冠李戴", false, true, 0, 150.447, false},
		{"负数曲长同样算「没有」", true, true, -1, 150.447, true},
	}
	for _, c := range cases {
		if got := needsRadioDurationBackfill(c.sameTrack, c.radio, c.sessDur, c.curDur); got != c.expect {
			t.Errorf("%s: needsRadioDurationBackfill(%v, %v, %v, %v) = %v, 期望 %v",
				c.name, c.sameTrack, c.radio, c.sessDur, c.curDur, got, c.expect)
		}
	}
}
