package main

import (
	"testing"
	"time"
)

var baseTestTime = time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)

func nowAt(offsetSecs int) time.Time {
	return baseTestTime.Add(time.Duration(offsetSecs) * time.Second)
}

func TestUpdatePosition_SteadyPlaybackDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	if reanchor, _ := p.updatePosition(nowAt(0)); !reanchor {
		t.Fatalf("first observation should reanchor")
	}

	base := 10.0
	for i := 1; i <= 5; i++ {
		p.cur.Elapsed = base + float64(i)*5
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: steady playback must not reanchor (elapsed=%v prevElapse=%v)", i, p.cur.Elapsed, p.prevElapse)
		}
	}
}

func TestUpdatePosition_RealSeekReanchors(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0))

	p.cur.Elapsed = 90
	reanchor, _ := p.updatePosition(nowAt(5))
	if !reanchor {
		t.Fatalf("a real seek (10s -> 90s over one 5s poll) must reanchor")
	}
	if p.trackPos != 90 {
		t.Fatalf("trackPos should snap to the seeked-to position, got %v", p.trackPos)
	}
}

func TestAppleScriptCorrectionFeedsBackIntoTrackPos(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0))

	p.cur.Elapsed = 15
	if reanchor, _ := p.updatePosition(nowAt(5)); reanchor {
		t.Fatalf("steady playback must not reanchor")
	}
	if p.trackPos != 15 {
		t.Fatalf("trackPos before correction should be 15, got %v", p.trackPos)
	}

	p.trackPos = 15.5
	p.prevWall = nowAt(5)

	p.cur.Elapsed = 20
	if reanchor, _ := p.updatePosition(nowAt(10)); reanchor {
		t.Fatalf("steady playback after correction must not reanchor")
	}
	if p.trackPos != 20.5 {
		t.Fatalf("trackPos should extrapolate from the corrected 15.5 baseline (want 20.5), got %v — correction was discarded", p.trackPos)
	}
}

func TestUpdatePosition_PauseDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0))

	p.cur.Playing = false
	p.cur.Rate = 0

	for i := 1; i <= 4; i++ {
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: paused must not reanchor", i)
		}
	}
}

func TestNaturalAdvanceCorrection(t *testing.T) {
	cases := []struct {
		name               string
		reported, overrun  float64
		wantOK             bool
		wantSeed, wantBias float64
	}{

		{"measured real transition", 0.048, -0.837, true, -0.837, 0.885},

		{"late metadata switch", 1.5, 0.6, true, 0.6, 0.9},

		{"manual skip mid-track", 0.3, -188, false, 0, 0},

		{"bias below noise floor", 0.3, 0.28, false, 0, 0},

		{"stale first sample", 30.3, -0.5, false, 0, 0},

		{"negative bias", 0.1, 0.9, false, 0, 0},
	}
	for _, c := range cases {
		seed, bias, ok := naturalAdvanceCorrection(c.reported, c.overrun)
		if ok != c.wantOK {
			t.Fatalf("%s: ok=%v want %v", c.name, ok, c.wantOK)
		}
		if !ok {
			continue
		}
		if diff := seed - c.wantSeed; diff > 1e-9 || diff < -1e-9 {
			t.Fatalf("%s: seed=%v want %v", c.name, seed, c.wantSeed)
		}
		if diff := bias - c.wantBias; diff > 1e-9 || diff < -1e-9 {
			t.Fatalf("%s: bias=%v want %v", c.name, bias, c.wantBias)
		}
	}
}

func TestUpdatePosition_NaturalAdvanceSeedsFromContinuity(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 280, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 285
	p.updatePosition(nowAt(5))
	p.cur.Elapsed = 290
	p.updatePosition(nowAt(10))

	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 236.266, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	reanchor, _ := p.updatePosition(baseTestTime.Add(12500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("track change must reanchor")
	}
	if diff := p.trackPos - (-0.5); diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("seed should be continuity overrun -0.5, got %v", p.trackPos)
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("bias should be 0.9, got %v", p.posBias)
	}
	if p.cur.Position != 0 {
		t.Fatalf("published position must clamp negative seed to 0, got %v", p.cur.Position)
	}

	p.cur.Elapsed = 5.4
	reanchor, _ = p.updatePosition(baseTestTime.Add(17500 * time.Millisecond))
	if reanchor {
		t.Fatalf("steady play after natural advance must not reanchor")
	}
	if diff := p.trackPos - 4.5; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("steady position should be 4.5 (true audio), got %v", p.trackPos)
	}

	p.cur.Elapsed = 60.2
	reanchor, _ = p.updatePosition(baseTestTime.Add(22500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("real seek must reanchor")
	}
	if p.posBias != 0 {
		t.Fatalf("real seek must clear posBias, got %v", p.posBias)
	}
	if diff := p.trackPos - 60.2; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("seek should adopt raw reading 60.2, got %v", p.trackPos)
	}
}

func TestUpdatePosition_ManualSkipKeepsRawSeed(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 100, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))

	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.3, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))
	if p.posBias != 0 {
		t.Fatalf("manual skip must not set bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 0.3; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("manual skip should seed raw 0.3, got %v", p.trackPos)
	}
}

func TestUpdatePosition_PauseSubtractsNaturalAdvanceBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("expected bias 1.9, got %v", p.posBias)
	}
	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0
	p.updatePosition(nowAt(10))
	if diff := p.trackPos - 18.1; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("paused position should subtract bias (20-1.9=18.1), got %v", p.trackPos)
	}
}

func TestUpdatePosition_ResumeKeepsNaturalAdvanceBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))

	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0
	p.updatePosition(nowAt(10))

	p.cur.Playing = true
	p.cur.Rate = 1
	p.cur.Elapsed = 22.0
	reanchor, _ := p.updatePosition(nowAt(15))
	if !reanchor {
		t.Fatalf("resume should reanchor (push relay promptly)")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("resume must keep bias 1.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 20.1; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("resume position should be 22-1.9=20.1, got %v", p.trackPos)
	}
}

func TestUpdatePosition_PausedExternalSeekClearsBias(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))

	p.cur.Playing = false
	p.cur.Rate = 0
	p.cur.Elapsed = 20.0
	p.updatePosition(nowAt(10))
	p.cur.Elapsed = 80.0
	p.updatePosition(nowAt(15))
	if p.posBias != 0 {
		t.Fatalf("paused external seek must clear bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 80.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("paused position should adopt raw 80, got %v", p.trackPos)
	}
}

func TestUpdatePosition_StaleSnapshotKeepsBiasAndContinuity(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))

	p.snapshotStale = true
	reanchor, _ := p.updatePosition(nowAt(10))
	if reanchor {
		t.Fatalf("stale round must not reanchor")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("stale round must keep bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 7.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("stale round should wall-clock advance 2+5=7, got %v", p.trackPos)
	}

	p.snapshotStale = false
	p.cur.Elapsed = 13.9
	reanchor, _ = p.updatePosition(nowAt(15))
	if reanchor {
		t.Fatalf("first fresh round after stale must not be misjudged as seek")
	}
	if diff := p.posBias - 1.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("bias must survive stale→fresh, got %v", p.posBias)
	}
	if diff := p.trackPos - 12.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("position should be 2+10=12, got %v", p.trackPos)
	}
}

func TestUpdatePosition_RepeatOneWrapSamePoll(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 193, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 198
	p.updatePosition(nowAt(5))

	p.cur.Elapsed = 3.9
	reanchor, loopRestart := p.updatePosition(nowAt(10))
	if !reanchor || !loopRestart {
		t.Fatalf("same-poll wrap should reanchor + fire loopRestart, got %v/%v", reanchor, loopRestart)
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap should re-estimate bias 0.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 3.0; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap should seed continuity overrun 3.0, got %v", p.trackPos)
	}
}

func TestUpdatePosition_RepeatOneWrapAfterLoopRestart(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 195, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur.Elapsed = 200
	_, loopRestart := p.updatePosition(nowAt(5))
	if !loopRestart {
		t.Fatalf("extrapolation crossing duration should fire loopRestart")
	}
	if p.trackPos != 0 {
		t.Fatalf("loopRestart should wrap trackPos to remainder 0, got %v", p.trackPos)
	}

	p.cur.Elapsed = 3.4
	reanchor, _ := p.updatePosition(baseTestTime.Add(7500 * time.Millisecond))
	if !reanchor {
		t.Fatalf("post-loopRestart wrap should reanchor")
	}
	if diff := p.posBias - 0.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap(a) should re-estimate bias 0.9, got %v", p.posBias)
	}
	if diff := p.trackPos - 2.5; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("wrap(a) should keep continuity 2.5, got %v", p.trackPos)
	}
}

func TestUpdatePosition_CrossPlayerOldTrackNoCorrection(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: qqMusicBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 3.9, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(5))
	if p.posBias != 0 {
		t.Fatalf("cross-player old track must not seed bias, got %v", p.posBias)
	}
	if diff := p.trackPos - 3.9; diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("should seed raw 3.9, got %v", p.trackPos)
	}
}

func TestUpdatePosition_NegativeSeedPublishesFutureAnchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 292, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(0))
	p.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	p.updatePosition(nowAt(2))

	p2 := &poller{}
	p2.cur = snapshot{Title: "Old", Artist: "A", Album: "Alb", Duration: 293, Playing: true, Elapsed: 290, Rate: 1, Bundle: spotifyBundleID}
	p2.updatePosition(nowAt(0))
	p2.cur = snapshot{Title: "New", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 0.4, Rate: 1, Bundle: spotifyBundleID}
	p2.updatePosition(baseTestTime.Add(2500 * time.Millisecond))
	if p2.cur.Position != 0 {
		t.Fatalf("negative seed must publish position 0, got %v", p2.cur.Position)
	}
	wantAt := baseTestTime.Add(2500 * time.Millisecond).Add(500 * time.Millisecond)
	if d := p2.cur.AnchorTS.Sub(wantAt); d > time.Millisecond || d < -time.Millisecond {
		t.Fatalf("anchor should be future-dated by 0.5s, got %v (want %v)", p2.cur.AnchorTS, wantAt)
	}
	if diff := p2.trackPos - (-0.5); diff > 1e-6 || diff < -1e-6 {
		t.Fatalf("internal trackPos should stay -0.5, got %v", p2.trackPos)
	}
}
