package main

import (
	"context"
	"errors"
	"log"
	"log/slog"
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

	lastfmExcluded bool

	lastfmPending *pendingLastfmListen
	lastfmSettled bool

	ended          bool
	endedNaturally bool

	lastPos   float64
	lastPosAt time.Time
}

type pendingLastfmListen struct {
	artistName string
	meta       snapshot
	startedAt  int64
}

func listenThreshold(duration float64) float64 {
	if duration > 0 {
		return min(duration/2, listenCapSecs)
	}
	return listenCapSecs
}

func tooShortToScrobble(durationSecs float64) bool {
	if durationSecs <= 0 || durationSecs >= minTrackSecs {
		return false
	}
	return !features.ScrobbleShortTracks
}

func shortTrackLastfmOnly(durationSecs float64) bool {
	return features.ScrobbleShortTracks && durationSecs > 0 && durationSecs < minTrackSecs
}

const (

	trackEndSlackSecs     = 12.0
	trackEndSlackFraction = 0.10

	trackEndMaxExtrapolateSecs = 2 * float64(pollInterval/time.Second)
)

func lastfmScrobblePointReached(s *playSession) bool {
	d := s.meta.Duration
	switch features.LastfmScrobblePoint {
	case scrobblePoint75:
		return d <= 0 || s.playedSecs >= 0.75*d
	case scrobblePoint90:
		return d <= 0 || s.playedSecs >= 0.90*d
	case scrobblePointEnd:
		return d <= 0 || s.endedNaturally
	default:
		return true
	}
}

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

func (p *poller) recordLastfmListen(s *playSession, artistName string, meta snapshot, startedAt int64) {
	if s.lastfmSettled || s.lastfmPending != nil {
		return
	}

	if artistName == "" {
		s.lastfmSettled = true
		log.Printf("lastfm: skipping scrobble without an artist: %q - %q", meta.Artist, meta.Title)
		return
	}

	if s.lastfmExcluded {
		s.lastfmSettled = true
		log.Printf("lastfm: skipping scrobble from excluded player %s: %q - %q", meta.Bundle, meta.Artist, meta.Title)
		return
	}
	s.lastfmPending = &pendingLastfmListen{artistName: artistName, meta: meta, startedAt: startedAt}
	if !p.settleLastfmPending(s) {
		slog.Debug("lastfm: scrobble deferred to scrobble point", "point", features.LastfmScrobblePoint,
			"played_secs", int(s.playedSecs), "duration_secs", int(meta.Duration), "artist", meta.Artist, "title", meta.Title)
	}
}

func (p *poller) settleLastfmPending(s *playSession) bool {
	if s.lastfmPending == nil || !lastfmScrobblePointReached(s) {
		return false
	}
	l := s.lastfmPending
	s.lastfmPending, s.lastfmSettled = nil, true
	p.mirrorScrobbleTracked(l.artistName, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Artist, l.meta.Duration)

	if p.lfm == nil {
		appendListen(l.meta.Artist, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Duration)
	}
	return true
}

func (p *poller) settleLastfmPendingSync(ctx context.Context, s *playSession) {
	if s.lastfmPending == nil || !lastfmScrobblePointReached(s) {
		return
	}
	l := s.lastfmPending
	s.lastfmPending, s.lastfmSettled = nil, true
	p.mirrorScrobbleSync(ctx, l.artistName, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Artist, l.meta.Duration)
	if p.lfm == nil {
		appendListen(l.meta.Artist, l.meta.Title, l.meta.albumForUpload(), l.startedAt, l.meta.Duration)
	}
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

	lfm         *lastfmScrobbler
	lfmMirrored map[int64]bool

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
	remoteTrack    snapshot
	remoteAt       time.Time
	lastListen     snapshot
	lastListenAt   int64
	lastListenDev  string

	forwardedSet    persistedTTLSet
	lfmMirroredSet  persistedTTLSet
	lastfmCheckedAt time.Time
	bridgeFetching  bool

	feedActivityAt   time.Time
	remoteKey        string
	remotePN         time.Time
	forwarded        map[int64]bool
	fwdSeeded        bool
	recentMacListens []recentListen

	weeklyState         weeklyDigestState
	weeklyLastCheckedAt time.Time

	dailyState         dailyDigestState
	dailyLastCheckedAt time.Time

	topArtistsState         topArtistsState
	topArtistsLastCheckedAt time.Time

	nullStreak int

	submitDoneCh   chan submitOutcome
	announceDoneCh chan announceOutcome

	bridgeDoneCh chan bridgeFetchResult
}

type bridgeFetchResult struct {
	now  time.Time
	page lastfmRecentPage
	ok   bool
}

const nearDuplicateWindow = 30 * time.Minute

const bridgeMaxListenAge = 3 * 24 * time.Hour

const recentMacListenRetention = 24 * time.Hour

type recentListen struct {
	artist, title string
	uts           int64
}

func (p *poller) recordRecentMacListen(artist, title string, uts int64) {
	p.recentMacListens = append(p.recentMacListens, recentListen{artist: artist, title: title, uts: uts})
	cutoff := uts - int64(recentMacListenRetention/time.Second)
	kept := p.recentMacListens[:0]
	for _, r := range p.recentMacListens {
		if r.uts >= cutoff {
			kept = append(kept, r)
		}
	}
	p.recentMacListens = kept
}

func (p *poller) recentlyPlayedOnMac(artist, title string, uts int64) bool {
	for _, r := range p.recentMacListens {
		artistOK := artistMatches(r.artist, artist) || looseContains(r.artist, artist)
		if !artistOK || !looseContains(r.title, title) {
			continue
		}
		d := uts - r.uts
		if d < 0 {
			d = -d
		}
		if d <= int64(nearDuplicateWindow/time.Second) {
			return true
		}
	}
	return false
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

func (p *poller) mirrorScrobbleTracked(artist, title, album string, timestamp int64, rawArtist string, durationSecs float64) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	if p.lfmMirrored[timestamp] {
		return
	}
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	mirrorAsync(p.lfm, "scrobble", func(ctx context.Context) error {
		err := p.lfm.scrobble(ctx, artist, title, album, timestamp, durationSecs)
		if err == nil {

			requestLastfmFeedRefresh(5 * time.Second)
		}
		return err
	}, func(err error) {
		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
	})
}

func recordFailedMirror(err error, rawArtist, title, album string, timestamp int64, durationSecs float64) {
	var ignored *lastfmIgnoredError
	if errors.As(err, &ignored) {
		return
	}
	appendListen(rawArtist, title, album, timestamp, durationSecs)

	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) {
		if apiErr.mayHaveStored() {
			markQuarantined(timestamp)
		}
		return
	}
	if !provablyNeverSent(err) {
		markQuarantined(timestamp)
	}
}

func (p *poller) mirrorScrobbleSync(ctx context.Context, artist, title, album string, timestamp int64, rawArtist string, durationSecs float64) {
	if p.lfm == nil || timestamp <= 0 {
		return
	}
	if p.lfm.dead.Load() {

		recordFailedMirror(&lastfmAPIError{Code: 9, Message: "mirror disabled (credentials judged dead)", Method: "track.scrobble"},
			rawArtist, title, album, timestamp, durationSecs)
		return
	}
	if p.lfmMirrored[timestamp] {
		return
	}
	p.lfmMirrored[timestamp] = true
	p.lfmMirroredSet.save(p.lfmMirrored)
	if err := p.lfm.scrobble(ctx, artist, title, album, timestamp, durationSecs); err != nil {
		log.Printf("lastfm mirror scrobble (final flush) failed: %v", err)

		recordFailedMirror(err, rawArtist, title, album, timestamp, durationSecs)
	}
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
	iphonePlaying := !p.remoteAt.IsZero() && now.Sub(p.remoteAt) < 90*time.Second
	switch {
	case macHasTrack && p.cur.Playing:
		payload = relayState(p.cur, true, "mac", 0, true)
		key = "mac|" + p.cur.key() + relayAlbumHintSuffix(p.cur)
	case iphonePlaying:
		payload = relayState(p.remoteTrack, true, "iphone", 0, true)
		key = "ip|" + p.remoteTrack.key()
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

func (p *poller) pushScrobble(s snapshot, listenedAt int64, device string) {
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
	sess *playSession
	meta snapshot

	artistName string
	startedAt  int64

	lastfmOnly bool
	err        error
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
	if shortTrackLastfmOnly(meta.Duration) {

		p.applySubmitOutcome(submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, lastfmOnly: true})
		return
	}
	go func() {
		err := p.lb.submit(p.ctx, "single", startedAt, lm)
		select {
		case p.submitDoneCh <- submitOutcome{sess: sess, meta: meta, artistName: lm.ArtistName, startedAt: startedAt, err: err}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) applySubmitOutcome(r submitOutcome) {
	r.sess.submitting = false

	p.recordLastfmListen(r.sess, r.artistName, r.meta, r.startedAt)
	if r.err != nil {
		log.Printf("submit listen failed: %v", r.err)
		return
	}
	r.sess.listenSent = true
	if r.lastfmOnly {
		log.Printf("listen recorded (Last.fm only, %.0fs track under %.0fs): %s - %s", r.meta.Duration, minTrackSecs, r.meta.Artist, r.meta.Title)
	} else {
		log.Printf("listen recorded: %s - %s", r.meta.Artist, r.meta.Title)
	}
	p.pushScrobble(r.meta, r.startedAt, "mac")
	p.recordRecentMacListen(r.meta.Artist, r.meta.Title, r.startedAt)
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
	if !p.settleLastfmPending(s) && s.lastfmPending != nil {
		slog.Debug("lastfm: session ended before scrobble point", "point", features.LastfmScrobblePoint,
			"played_secs", int(s.playedSecs), "duration_secs", int(s.meta.Duration), "artist", s.meta.Artist, "title", s.meta.Title)
	}
	if s.listenSent || s.submitting || tooShortToScrobble(s.meta.Duration) {
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

	artist, title, album := m.ArtistName, p.cur.Title, p.cur.albumForUpload()

	durationSecs := p.cur.Duration
	playing := p.cur.Playing

	lastfmSkip := p.sess.lastfmExcluded
	go func() {

		if playing && !lastfmSkip {
			mirrorAsync(p.lfm, "now-playing", func(ctx context.Context) error {
				return p.lfm.updateNowPlaying(ctx, artist, title, album, durationSecs)
			}, nil)
		}
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
			p.sess.lastfmExcluded = lastfmExcluded(p.cur.Bundle)
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
		p.sess.lastfmExcluded = lastfmExcluded(p.cur.Bundle)
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
	p.settleLastfmPending(p.sess)

	if !submitted && (reanchored || now.Sub(p.sess.lastPN) >= playingNowRefresh) {
		p.announce(now, "refresh")
	}
	if !p.sess.listenSent && !p.sess.submitting && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
		!tooShortToScrobble(p.sess.meta.Duration) {
		p.sess.submitting = true
		p.submitSingleAsync(p.sess, p.sess.meta, p.sess.startedAt.Unix())
	}
}

func (p *poller) bridge(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.lastfmBridgeAPIKey() == "" {
		return
	}
	if p.bridgeFetching {
		return
	}
	localPlaying := p.cur.Playing && p.isTracked()
	due := now.Sub(p.lastfmCheckedAt) >= lastfmFeedInterval(localPlaying, p.feedActivityAt, now)

	if lastfmFeedNudgeFileDue() {
		requestLastfmFeedRefresh(backfillFeedNudgeDelay)
	}

	if !due && !lastfmFeedNudgeDue(now) {
		return
	}
	p.lastfmCheckedAt = now
	p.bridgeFetching = true
	user, apiKey := p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey()
	go func() {
		page, ok := lastfmRecent(p.ctx, user, apiKey)
		select {
		case p.bridgeDoneCh <- bridgeFetchResult{now: now, page: page, ok: ok}:
		case <-p.ctx.Done():
		}
	}()
}

func (p *poller) bridgeForwardingEnabled() bool {
	return p.cfg.User != "" && p.cfg.Token != ""
}

func (p *poller) applyBridgeResult(r bridgeFetchResult) {
	p.bridgeFetching = false
	if !r.ok {
		return
	}

	writeLastfmRecentFeed(p.cfg.LastfmUser, r.page, r.now)
	if at := lastfmFeedActivityAt(r.page, r.now); !at.IsZero() && at.After(p.feedActivityAt) {
		p.feedActivityAt = at
	}
	if !p.bridgeForwardingEnabled() {
		return
	}

	defer p.pushRelayState(time.Now(), false)
	now, np, done := r.now, r.page.NowPlaying, r.page.Done

	fwdChanged := false
	if !p.fwdSeeded {
		for _, s := range done {
			if s.UTS > 0 {
				p.forwarded[s.UTS] = true
			}
		}
		p.fwdSeeded, fwdChanged = true, true
	} else {
		for i := len(done) - 1; i >= 0; i-- {
			s := done[i]

			if s.UTS > 0 && now.Unix()-s.UTS > int64(bridgeMaxListenAge/time.Second) {
				continue
			}
			if s.UTS <= 0 || p.forwarded[s.UTS] {
				continue
			}
			if p.lfmMirrored[s.UTS] {

				p.forwarded[s.UTS], fwdChanged = true, true
				continue
			}
			if p.recentlyPlayedOnMac(s.Artist, s.Title, s.UTS) {

				p.forwarded[s.UTS], fwdChanged = true, true
				continue
			}
			m := lbMeta(snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album})
			m.AdditionalInfo["source"] = "iphone"
			m.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone

			if err := p.lb.submit(p.ctx, "single", s.UTS, m); err != nil {
				if errors.Is(err, errListenRejected) {

					log.Printf("bridge: skip rejected lastfm listen %q - %q: %v", s.Artist, s.Title, err)
					p.forwarded[s.UTS], fwdChanged = true, true
					continue
				}

				log.Printf("bridge: forward lastfm listen failed, will retry: %v", err)
				break
			}
			log.Printf("bridge: listen from iPhone/Last.fm: %s - %s", s.Artist, s.Title)
			p.pushScrobble(snapshot{Title: s.Title, Artist: s.Artist, Album: s.Album}, s.UTS, "iphone")
			p.forwarded[s.UTS], fwdChanged = true, true
		}
	}

	if p.forwardedSet.trim(p.forwarded, now) {
		fwdChanged = true
	}
	if fwdChanged {
		p.forwardedSet.save(p.forwarded)
	}

	if p.lfmMirroredSet.trim(p.lfmMirrored, now) {
		p.lfmMirroredSet.save(p.lfmMirrored)
	}

	macActive := p.cur.Playing && p.isTracked()
	if macActive {
		p.remoteKey = ""
		p.remoteAt = time.Time{}
		return
	}
	if np == nil {
		p.remoteAt = time.Time{}
		return
	}
	if p.lfm != nil && looseContains(np.Artist, p.cur.Artist) && looseContains(np.Title, p.cur.Title) && p.cur.Title != "" {

		return
	}

	p.remoteTrack, p.remoteAt = snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true}, now
	key := np.Title + "|" + np.Artist
	if key == p.remoteKey && now.Sub(p.remotePN) < playingNowRefresh {
		return
	}
	p.remoteKey, p.remotePN = key, now
	meta := lbMeta(snapshot{Title: np.Title, Artist: np.Artist, Album: np.Album, Playing: true})
	meta.AdditionalInfo["source"] = "iphone"
	meta.AdditionalInfo["media_player"] = mediaPlayerLabelIPhone
	artist, title := np.Artist, np.Title

	go func() {
		if err := p.lb.submit(p.ctx, "playing_now", 0, meta); err != nil {
			log.Printf("bridge: submit lastfm playing_now failed: %v", err)
		} else {
			log.Printf("bridge: now playing (iPhone via Last.fm): %s - %s", artist, title)
		}
	}()
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
	p.bridge(now)
	p.pushRelayState(now, reanchored)
	p.weeklyDigest(now)
	p.dailyDigest(now)
	p.topArtistsDigest(now)
}

func run(ctx context.Context, cfg *config, lb *lbClient) error {
	forwardedSet := persistedTTLSet{path: forwardedPath, ttl: forwardedTTL}
	lfmMirroredSet := persistedTTLSet{path: lfmMirroredPath, ttl: lfmMirroredTTL}
	forwarded, fwdSeeded := forwardedSet.load()
	lfmMirrored, _ := lfmMirroredSet.load()
	p := &poller{
		ctx: ctx,
		cfg: cfg,
		lb:  lb,

		lfm:             lastfmScrobblerIfEnabled(cfg),
		lfmMirrored:     lfmMirrored,
		forwardedSet:    forwardedSet,
		lfmMirroredSet:  lfmMirroredSet,
		forwarded:       forwarded,
		fwdSeeded:       fwdSeeded,
		weeklyState:     weeklyDigestState{path: weeklyDigestPath},
		dailyState:      dailyDigestState{path: dailyDigestPath},
		topArtistsState: topArtistsState{path: topArtistsStatePath},
		submitDoneCh:    make(chan submitOutcome, 8),
		announceDoneCh:  make(chan announceOutcome, 8),
		bridgeDoneCh:    make(chan bridgeFetchResult, 1),
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
				p.settleLastfmPendingSync(flushCtx, p.sess)
			}
			if p.sess != nil && !p.sess.listenSent && p.sess.playedSecs >= listenThreshold(p.sess.meta.Duration) &&
				!tooShortToScrobble(p.sess.meta.Duration) &&
				!p.sess.isAd && !isAdBreak(p.sess.meta.Bundle, p.sess.meta.Artist, p.sess.meta.Title, p.sess.meta.Album) {

				lm := lbMeta(p.sess.meta)

				if !p.sess.lastfmSettled && p.sess.lastfmPending == nil && !p.sess.lastfmExcluded {
					p.sess.lastfmPending = &pendingLastfmListen{artistName: lm.ArtistName, meta: p.sess.meta, startedAt: p.sess.startedAt.Unix()}
				}
				p.settleLastfmPendingSync(flushCtx, p.sess)

				if shortTrackLastfmOnly(p.sess.meta.Duration) {
					p.recordRecentMacListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.startedAt.Unix())
				} else if err := lb.submit(flushCtx, "single", p.sess.startedAt.Unix(), lm); err != nil {
					log.Printf("final listen flush failed: %v", err)
				} else {
					p.recordRecentMacListen(p.sess.meta.Artist, p.sess.meta.Title, p.sess.startedAt.Unix())
				}

				p.pushScrobble(p.sess.meta, p.sess.startedAt.Unix(), "mac")
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
		case r := <-p.bridgeDoneCh:
			p.applyBridgeResult(r)
		}
	}
}
