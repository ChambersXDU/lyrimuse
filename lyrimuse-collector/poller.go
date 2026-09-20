package main

import (
	"context"
	"log"
	"math"
	"slices"
	"time"
)

type playSession struct {
	key         string
	meta        snapshot
	startedAt   time.Time
	playedSecs  float64
	lastSeen    time.Time
	listenSent  bool
	lastPN      time.Time
	lastPlaying bool
	pnPending   bool

	submitting bool
	announcing bool

	isAd bool

	ended          bool
	endedNaturally bool

	lastPos   float64
	lastPosAt time.Time
}

func listenThreshold(duration float64) float64 {
	if duration > 0 {
		return min(duration/2, listenCapSecs)
	}
	return listenCapSecs
}

func tooShortToSubmit(durationSecs float64) bool {
	if durationSecs <= 0 || durationSecs >= minTrackSecs {
		return false
	}
	return true
}

const (
	trackEndSlackSecs     = 12.0
	trackEndSlackFraction = 0.10

	trackEndMaxExtrapolateSecs = 2 * float64(pollInterval/time.Second)
)

func sessionEndedNaturally(s *playSession, now time.Time) bool {
	d := s.meta.Duration
	if d <= 0 || s.lastPosAt.IsZero() {
		return false
	}
	pos := s.lastPos
	if s.lastPlaying {
		pos += min(max(now.Sub(s.lastPosAt).Seconds(), 0), trackEndMaxExtrapolateSecs)
	}
	return pos >= d-trackEndSlack(d)
}

func trackEndSlack(duration float64) float64 {
	return min(trackEndSlackSecs, duration*trackEndSlackFraction)
}

func seedPosition(elapsed, rate float64, playing bool, mcTS, now time.Time) float64 {
	p := elapsed
	if !playing {
		return p
	}
	if rate == 0 {
		rate = 1
	}
	if !mcTS.IsZero() {
		if d := now.Sub(mcTS).Seconds(); d > 0 {
			p += d * rate
		}
	}
	return p
}

type poller struct {
	ctx context.Context
	cfg *config
	lb  *lbClient

	cur  snapshot
	sess *playSession

	recentFinalized   *playSession
	recentFinalizedAt time.Time

	trackPos   float64
	trackKey   string
	prevElapse float64
	prevWall   time.Time

	posBias      float64
	prevDuration float64
	prevPlaying  bool
	prevBundle   string

	prevLoopRestart bool

	snapshotStale bool

	relayLastState string
	relayLastAt    time.Time
	relayWrites    int
	relayFailKey   string
	relayFailAt    time.Time
	relayBackoff   time.Duration
	lastListen     snapshot
	lastListenAt   int64
	lastListenDev  string

	weeklyState         weeklyDigestState
	weeklyLastCheckedAt time.Time

	dailyState         dailyDigestState
	dailyLastCheckedAt time.Time

	nullStreak int

	submitDoneCh   chan submitOutcome
	announceDoneCh chan announceOutcome
}

func (p *poller) isTracked() bool {
	if p.cur.key() == "" {
		return false
	}
	if slices.Contains(p.cfg.BundleIDs, p.cur.Bundle) {
		return true
	}

	if features.Players[playerAuto] {
		return isAcceptedPlayerBundleID(p.cur.Bundle)
	}
	for player := range features.Players {
		if p.cur.Bundle == playerBundleID(player) {
			return true
		}
	}

	return isTrustedPlayerBundleID(p.cur.Bundle)
}

const (
	loopRestartMinElapsedFrac    = 0.9
	loopRestartMaxNewElapsedSecs = 10.0

	seekJumpToleranceSecs = 2.0

	naturalAdvanceWindowSecs = 6.5

	naturalAdvanceMaxBiasSecs = 2.5
	naturalAdvanceMinBiasSecs = 0.05
)

func naturalAdvanceCorrection(reported, overrun float64) (seed, bias float64, ok bool) {
	if math.Abs(overrun) > naturalAdvanceWindowSecs {
		return 0, 0, false
	}
	bias = reported - overrun
	if bias <= naturalAdvanceMinBiasSecs || bias > naturalAdvanceMaxBiasSecs {
		return 0, 0, false
	}
	return overrun, bias, true
}

func (p *poller) updatePosition(now time.Time) (reanchor bool, loopRestart bool) {
	key := p.cur.key()
	if key == "" {
		p.trackKey, p.prevWall = "", time.Time{}
		p.posBias, p.prevDuration, p.prevPlaying, p.prevBundle = 0, 0, false, ""
		p.prevLoopRestart = false
		p.cur.Position, p.cur.AnchorTS = 0, now
		return false, false
	}
	sameTrackAsBefore := key == p.trackKey
	prevTrackPos := p.trackPos
	gap := now.Sub(p.prevWall).Seconds()
	reanchor = true

	rate := p.cur.Rate
	if p.cur.Playing && rate <= 0 {
		rate = 1
	}
	if p.cur.Bundle != spotifyBundleID && p.posBias != 0 {

		p.posBias = 0
	}
	if sameTrackAsBefore && !p.snapshotStale && p.posBias != 0 && p.cur.AnchorElapsed > 0.001 {

		p.posBias = 0
	}
	seedFromMC := func() float64 { return seedPosition(p.cur.Elapsed, p.cur.Rate, p.cur.Playing, p.cur.McTS, now) }

	wrapSeed, wrapBias := 0.0, 0.0
	wrapOK := false
	if sameTrackAsBefore && !p.snapshotStale && p.cur.Playing && p.prevPlaying &&
		p.cur.Bundle == spotifyBundleID && p.prevBundle == spotifyBundleID && p.prevDuration > 0 {
		if p.prevLoopRestart {
			base := prevTrackPos + gap*rate
			if b := seedFromMC() - base; b > naturalAdvanceMinBiasSecs && b <= naturalAdvanceMaxBiasSecs {
				wrapSeed, wrapBias, wrapOK = base, b, true
			}
		} else {
			wrapSeed, wrapBias, wrapOK = naturalAdvanceCorrection(seedFromMC(), prevTrackPos+gap*rate-p.prevDuration)
		}
	}
	switch {
	case p.snapshotStale && sameTrackAsBefore:

		if p.cur.Playing {
			p.trackPos += gap * rate

			p.cur.Elapsed += gap * rate
		}
		reanchor = false
	case key != p.trackKey:

		p.posBias = 0
		p.trackPos = seedFromMC()
		if p.cur.Bundle == spotifyBundleID && p.prevBundle == spotifyBundleID &&
			p.cur.Playing && p.prevPlaying && p.prevDuration > 0 && !p.prevWall.IsZero() {
			overrun := prevTrackPos + gap*rate - p.prevDuration
			if seed, bias, ok := naturalAdvanceCorrection(p.trackPos, overrun); ok {
				log.Printf("natural advance: seed %.3fs, anchor leads audio by %.3fs (raw %.3f)", seed, bias, p.trackPos)
				p.trackPos, p.posBias = seed, bias
			}
		}
	case !p.cur.Playing:

		if !p.prevPlaying && p.posBias != 0 &&
			math.Abs(p.cur.Elapsed-p.prevElapse) > seekJumpToleranceSecs {
			p.posBias = 0
		}
		p.trackPos = p.cur.Elapsed - p.posBias

		reanchor = false
	case !p.prevPlaying:

		p.trackPos = p.cur.Elapsed - p.posBias
	case wrapOK:
		log.Printf("repeat-one wrap: seed %.3fs, anchor leads audio by %.3fs", wrapSeed, wrapBias)
		p.trackPos, p.posBias = wrapSeed, wrapBias
	case math.Abs(p.cur.Elapsed-(p.prevElapse+gap*rate)) > seekJumpToleranceSecs:

		p.posBias = 0
		p.trackPos = seedFromMC()
	case p.prevWall.IsZero():
		p.posBias = 0
		p.trackPos = seedFromMC()
	case gap > 3*pollInterval.Seconds():
		p.posBias = 0
		p.trackPos = p.cur.Elapsed
	default:
		p.trackPos += gap * rate
		reanchor = false
	}

	if sameTrackAsBefore && !p.snapshotStale && p.cur.Playing && p.cur.Duration > 0 &&
		prevTrackPos >= p.cur.Duration*loopRestartMinElapsedFrac &&
		(p.trackPos >= p.cur.Duration || p.trackPos <= loopRestartMaxNewElapsedSecs) {
		loopRestart = true
		reanchor = true
		if p.trackPos >= p.cur.Duration {
			p.trackPos -= p.cur.Duration
		}
	}
	if p.cur.Duration > 0 && p.trackPos > p.cur.Duration {
		p.trackPos = p.cur.Duration
	}
	p.trackKey, p.prevElapse, p.prevWall = key, p.cur.Elapsed, now
	p.prevDuration, p.prevPlaying, p.prevBundle = p.cur.Duration, p.cur.Playing, p.cur.Bundle
	p.prevLoopRestart = loopRestart

	pub := p.trackPos
	pubAt := now
	if pub < 0 {

		pubAt = now.Add(time.Duration(-pub * float64(time.Second)))
		pub = 0
	}
	p.cur.Position, p.cur.AnchorTS = pub, pubAt
	return reanchor, loopRestart
}

func (p *poller) pushRelayState(now time.Time, reanchored bool) {
	if p.cfg.StateRelayURL == "" {
		return
	}
	var payload map[string]any
	key := ""

	macHasTrack := p.isTracked() && !isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) &&
		!(p.sess != nil && p.sess.isAd)
	switch {
	case macHasTrack && p.cur.Playing:
		payload = relayState(p.cur, true, "mac", 0, true)
		key = "mac|" + p.cur.key() + relayAlbumHintSuffix(p.cur)
	case macHasTrack:
		payload = relayState(p.cur, false, "mac", 0, true)
		key = "macpause|" + p.cur.key() + relayAlbumHintSuffix(p.cur)
	case p.lastListen.key() != "":
		payload = relayState(p.lastListen, false, p.lastListenDev, p.lastListenAt, false)
		key = "last|" + p.lastListen.key() + relayAlbumHintSuffix(p.lastListen)
	default:
		payload = map[string]any{"ok": true, "empty": true, "playing": false}
		key = "empty"
	}

	if cov, _ := payload["artwork"].(string); cov != "" {
		key += "|c"
	}
	changed := key != p.relayLastState
	if !changed && !reanchored && now.Sub(p.relayLastAt) < 4*time.Minute {
		return
	}
	writeReason := "heartbeat"
	if changed {
		writeReason = "change"
	} else if reanchored {
		writeReason = "reanchor"
	}

	if key != p.relayFailKey {
		p.relayFailAt, p.relayBackoff = time.Time{}, 0
	}
	if !p.relayFailAt.IsZero() && now.Sub(p.relayFailAt) < p.relayBackoff {
		return
	}
	if err := postRelay(p.ctx, p.cfg, "/push", payload); err != nil {
		log.Printf("relay push failed: %v", err)
		p.relayFailKey, p.relayFailAt = key, now
		if p.relayBackoff == 0 {
			p.relayBackoff = 30 * time.Second
		} else if p.relayBackoff < 10*time.Minute {
			p.relayBackoff *= 2
		}
		return
	}
	p.relayFailAt, p.relayBackoff, p.relayFailKey = time.Time{}, 0, ""
	p.relayLastState, p.relayLastAt = key, now
	p.relayWrites++
	log.Printf("relay write #%d [%s] key=%q", p.relayWrites, writeReason, key)
}

func (p *poller) recordSubmittedListen(s snapshot, listenedAt int64, device string) {
	p.lastListen, p.lastListenAt, p.lastListenDev = s, listenedAt, device
}

func (p *poller) albumHintFor(s snapshot) string {
	if s.Album != "" || s.Title == "" || s.Artist == "" || isAdBreak(s.Bundle, s.Artist, s.Title, s.Album) {
		return ""
	}
	return appleAlbumHint(p.ctx, s.Artist, s.Title, s.Duration, lyricResolvedArtists(s.Artist, s.Title, s.Album))
}

func relayAlbumHintSuffix(s snapshot) string {
	if s.Album == "" && s.AlbumHint != "" {
		return "|a"
	}
	return ""
}

type submitOutcome struct {
	sess      *playSession
	meta      snapshot
	startedAt int64
	err       error
}

type announceOutcome struct {
	sess *playSession
	at   time.Time
	ok   bool
}

func (p *poller) submitSingleAsync(sess *playSession, meta snapshot, startedAt int64) {

	if sess.isAd || isAdBreak(meta.Bundle, meta.Artist, meta.Title, meta.Album) {
		log.Printf("skipping ad break: %q - %q", meta.Artist, meta.Title)
		sess.listenSent = true
		return
	}
	lm := lbMeta(meta)

	if lm.ArtistName == "" {
		log.Printf("skipping listen without an artist: %q - %q", meta.Artist, meta.Title)
		sess.listenSent = true
		return
	}
	go func() {
		err := p.lb.submit(p.ctx, "single", startedAt, lm)
		select {
		case p.submitDoneCh <- submitOutcome{sess: sess, meta: meta, startedAt: startedAt, err: err}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) applySubmitOutcome(r submitOutcome) {
	r.sess.submitting = false

	if r.err != nil {
		log.Printf("submit listen failed: %v", r.err)
		return
	}
	r.sess.listenSent = true
	log.Printf("listen recorded: %s - %s", r.meta.Artist, r.meta.Title)
	p.recordSubmittedListen(r.meta, r.startedAt, "mac")
	p.pushRelayState(time.Now(), false)
}

func (p *poller) applyAnnounceOutcome(r announceOutcome) {
	r.sess.announcing = false
	if !r.ok {
		return
	}
	r.sess.lastPN = r.at
	r.sess.pnPending = false
	p.pushRelayState(time.Now(), false)
}

func (p *poller) finalize(now time.Time) {
	if p.sess == nil {
		return
	}
	s := p.sess
	p.sess = nil
	p.recentFinalized, p.recentFinalizedAt = s, now

	s.ended, s.endedNaturally = true, sessionEndedNaturally(s, now)
	if s.listenSent || s.submitting || tooShortToSubmit(s.meta.Duration) {
		return
	}
	if s.playedSecs < listenThreshold(s.meta.Duration) {
		return
	}
	s.submitting = true
	p.submitSingleAsync(s, s.meta, s.startedAt.Unix())
}

func (p *poller) detectAdAtSessionStart() bool {
	if isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		return true
	}
	if p.cur.Bundle == spotifyBundleID {
		uri, ok := spotifyCurrentTrackURI(p.ctx)
		if !ok {
			return false
		}

		if id := spotifyTrackIDFromURI(uri); id != "" {
			noteSpotifyTrackID(p.cur.Artist, p.cur.Title, p.cur.Album, id)
		}
		return spotifyURIIsAd(uri)
	}
	return false
}

func (p *poller) announce(now time.Time, why string) {
	if p.sess.announcing {
		return
	}

	if p.sess.isAd || isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		return
	}

	if p.cur.Artist == "" {
		return
	}
	p.sess.announcing = true
	sess := p.sess
	m := lbMeta(p.cur)

	go func() {
		err := p.lb.submit(p.ctx, "playing_now", 0, m)
		if err != nil {
			log.Printf("submit playing_now (%s) failed: %v", why, err)
		}
		select {
		case p.announceDoneCh <- announceOutcome{sess: sess, at: now, ok: err == nil}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) handle(now time.Time, reanchored, loopRestart bool) {
	key := p.cur.key()
	isMusic := p.isTracked()

	if p.sess != nil && p.sess.key == key && p.sess.meta.AlbumHint == "" && p.cur.AlbumHint != "" {
		p.sess.meta.AlbumHint = p.cur.AlbumHint
	}

	if p.sess != nil && needsRadioDurationBackfill(p.sess.key == key, p.cur.Radio,
		p.sess.meta.Duration, p.cur.Duration) {
		p.sess.meta.Duration = p.cur.Duration
	}

	if !isMusic {
		if p.sess != nil {
			p.sess.lastSeen = time.Time{}
			p.finalize(now)
		}
		return
	}

	if p.sess == nil || p.sess.key != key {
		p.finalize(now)
		if p.recentFinalized != nil && p.recentFinalized.key == key && now.Sub(p.recentFinalizedAt) < nullResumeGraceWindow {

			p.sess = p.recentFinalized
			p.sess.pnPending = false
			p.sess.ended = false
		} else {
			p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
			if p.cur.Playing {
				p.sess.lastSeen = now
			}
			p.sess.isAd = p.detectAdAtSessionStart()
		}
		p.recentFinalized = nil
		log.Printf("now playing: %s - %s", p.cur.Artist, p.cur.Title)

		if features.AlbumPrefetch {
			prefetchAlbumSiblings(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle)
		}

		if len(trackEnrichment(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, true, p.cur.Radio)) > 0 {
			p.announce(now, "new")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	if loopRestart {
		p.finalize(now)
		p.recentFinalized = nil
		p.sess = &playSession{key: key, meta: p.cur, startedAt: now, lastPlaying: p.cur.Playing}
		if p.cur.Playing {
			p.sess.lastSeen = now
		}
		p.sess.isAd = p.detectAdAtSessionStart()
		log.Printf("loop restart: %s - %s", p.cur.Artist, p.cur.Title)
		if len(trackEnrichment(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, true, p.cur.Radio)) > 0 {
			p.announce(now, "loop restart")
		} else {
			p.sess.pnPending = true
		}
		return
	}

	if !p.sess.isAd && isAdBreak(p.cur.Bundle, p.cur.Artist, p.cur.Title, p.cur.Album) {
		p.sess.isAd = true
		log.Printf("ad break detected mid-session: %q - %q", p.cur.Artist, p.cur.Title)
	}

	submitted := false

	if p.sess.pnPending {

		resolved := len(trackEnrichment(p.ctx, p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Bundle, p.cur.Duration, false, p.cur.Radio)) > 0
		if resolved || now.Sub(p.sess.startedAt) >= pnPendingMax {
			p.announce(now, "first")
		}
		submitted = true
	}

	if p.cur.Playing != p.sess.lastPlaying {
		p.sess.lastPlaying = p.cur.Playing
		if p.cur.Playing {
			p.sess.lastSeen = now
		} else {
			p.sess.lastSeen = time.Time{}
		}
		if !p.sess.pnPending {
			p.announce(now, "state change")
			submitted = true
		}
	}

	if !p.cur.Playing {
		return
	}

	if !p.sess.lastSeen.IsZero() {
		if d := now.Sub(p.sess.lastSeen).Seconds(); d > 0 && d <= maxAccrualGapSecs {
			p.sess.playedSecs += d
		}
	}
	p.sess.lastSeen = now

	if at := p.cur.AnchorTS; at.IsZero() {
		p.sess.lastPos, p.sess.lastPosAt = p.cur.Position, now
	} else {
		p.sess.lastPos, p.sess.lastPosAt = p.cur.Position, at
	}
	if !submitted && (reanchored || now.Sub(p.sess.lastPN) >= playingNowRefresh) {
		p.announce(now, "refresh")
	}
	if !p.sess.listenSent && !p.sess.submitting && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
		!tooShortToSubmit(p.sess.meta.Duration) {
		p.sess.submitting = true
		p.submitSingleAsync(p.sess, p.sess.meta, p.sess.startedAt.Unix())
	}
}

func borrowAppleScriptPosition(applePlayerSelected bool, bundle string, playing, tracked, radio bool) bool {
	return applePlayerSelected && bundle == appleMusicBundleID && playing && tracked && !radio
}

func needsRadioDurationBackfill(sameTrack, radio bool, sessionDuration, currentDuration float64) bool {
	return sameTrack && radio && sessionDuration <= 0 && currentDuration > 0
}

func (p *poller) poll() {

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

			applyRadioClock(&p.cur, time.Now())

			if p.cur.Radio {
				noteRadioDuration(p.cur.Artist, p.cur.Title, p.cur.Album, p.cur.Duration)
			}

			p.cur.AlbumHint = p.albumHintFor(p.cur)
			p.snapshotStale = false
		}
	}
	now := time.Now()
	reanchored, loopRestart := p.updatePosition(now)

	if borrowAppleScriptPosition(features.Players[playerAppleMusic], p.cur.Bundle,
		p.cur.Playing, p.isTracked(), p.cur.Radio) {
		if pos, ok := appleMusicPosition(p.ctx); ok {
			correctedAt := time.Now()
			p.cur.Position, p.cur.AnchorTS = pos, correctedAt

			p.trackPos = pos
			p.prevWall = correctedAt
		}
	}
	p.handle(now, reanchored, loopRestart)
	p.pushRelayState(now, reanchored)
	p.weeklyDigest(now)
	p.dailyDigest(now)
}

func run(ctx context.Context, cfg *config, lb *lbClient) error {
	p := &poller{
		ctx:            ctx,
		cfg:            cfg,
		lb:             lb,
		weeklyState:    weeklyDigestState{path: weeklyDigestPath},
		dailyState:     dailyDigestState{path: dailyDigestPath},
		submitDoneCh:   make(chan submitOutcome, 8),
		announceDoneCh: make(chan announceOutcome, 8),
	}
	enrichNotify = make(chan struct{}, 1)
	p.poll()
	go startCompanionLaunchWatcher(ctx)
	go startEnrichCancelWatcher(ctx)
	go startLyricsFillSweeper(ctx)

	playbackWake := make(chan struct{}, 1)
	go watchPlaybackEvents(ctx, mediaControlBinaryPath(), playbackWake)
	var playbackDebounce *time.Timer
	var playbackReady <-chan time.Time
	defer func() {
		if playbackDebounce != nil {
			playbackDebounce.Stop()
		}
	}()
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():

			flushCtx, cancel := context.WithTimeout(context.Background(), submitTimeout)
			defer cancel()

			if p.sess != nil {
				p.sess.ended, p.sess.endedNaturally = true, sessionEndedNaturally(p.sess, time.Now())
			}
			if p.sess != nil && !p.sess.listenSent && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
				!tooShortToSubmit(p.sess.meta.Duration) &&
				!p.sess.isAd && !isAdBreak(p.sess.meta.Bundle, p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album) {

				lm := lbMeta(p.sess.meta)
				if lm.ArtistName == "" {
					return nil
				}
				if err := lb.submit(flushCtx, "single", p.sess.startedAt.Unix(), lm); err != nil {
					log.Printf("final listen flush failed: %v", err)
				} else {
					p.recordSubmittedListen(p.sess.meta, p.sess.startedAt.Unix(), "mac")
				}
			}
			return nil
		case <-enrichNotify:
			p.poll()
		case <-playbackWake:
			if playbackReady == nil {
				playbackDebounce = time.NewTimer(120 * time.Millisecond)
				playbackReady = playbackDebounce.C
			}
		case <-playbackReady:
			playbackReady = nil
			p.poll()
		case <-ticker.C:
			p.poll()
		case r := <-p.submitDoneCh:
			p.applySubmitOutcome(r)
		case r := <-p.announceDoneCh:
			p.applyAnnounceOutcome(r)
		}
	}
}
