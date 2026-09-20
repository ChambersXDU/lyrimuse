package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"math"
	neturl "net/url"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

func songLanguageFromScored(scored []scoredLyricCandidateResult) string {
	for _, c := range scored {
		if c.Language != "" {
			return c.Language
		}
	}
	return ""
}

func needsRomanizationRetry(results []scoredLyricCandidateResult) bool {
	needsScript := false
	for _, r := range results {
		if r.LyricsRoma != "" || r.Language != "" {
			return false
		}
		if r.Lyrics == "" {
			continue
		}
		switch dominantScript(r.Lyrics) {
		case scriptHan, scriptKana, scriptHangul:
			needsScript = true
		}
	}
	return needsScript
}

func (e *enrichEntry) maybeGenerateJyutpingRoma() {
	if e.SongLanguage == songLanguageCantonese && e.Lyrics != "" && e.LyricsRoma == "" {
		e.LyricsRoma = jyutpingLRC(e.Lyrics)
	}
}

type enrichEntry struct {
	CoverURL string `json:"cover_url,omitempty"`

	MotionCoverURL   string `json:"motion_cover_url,omitempty"`
	MotionPreviewURL string `json:"motion_preview_url,omitempty"`

	MotionCoverChecked bool   `json:"motion_cover_checked,omitempty"`
	AccentColor        string `json:"accent_color,omitempty"`
	NeteaseURL         string `json:"netease_url,omitempty"`
	AppleURL           string `json:"apple_music_url,omitempty"`
	QQURL              string `json:"qq_music_url,omitempty"`

	QQAlbumMid  string `json:"qq_album_mid,omitempty"`
	QQSingerMid string `json:"qq_singer_mid,omitempty"`
	SpotifyURL  string `json:"spotify_url,omitempty"`
	Lyrics      string `json:"lyrics,omitempty"`
	LyricsTr    string `json:"lyrics_tr,omitempty"`

	LyricsRoma string `json:"lyrics_roma,omitempty"`

	PlainLyrics string `json:"plain_lyrics,omitempty"`

	PlainLyricsSource string `json:"plain_lyrics_source,omitempty"`
	LyricsYRC         string `json:"lyrics_yrc,omitempty"`

	SongLanguage string `json:"song_language,omitempty"`

	CanonicalArtist string `json:"canonical_artist,omitempty"`

	CoverSource  string `json:"cover_source,omitempty"`
	LyricsSource string `json:"lyrics_source,omitempty"`

	CoverAlbum string `json:"cover_album,omitempty"`

	LyricsScore       int      `json:"lyrics_score,omitempty"`
	LyricsSourcesSeen []string `json:"lyrics_sources_seen,omitempty"`

	LyricsSourcesResponded []string `json:"lyrics_sources_responded,omitempty"`

	LyricsSourcesSkipped []string `json:"lyrics_sources_skipped,omitempty"`

	LyricsSourcesFailed []string `json:"lyrics_sources_failed,omitempty"`

	LyricsDecision *lyricsDecision `json:"lyrics_decision,omitempty"`

	LyricsDecisionApplied *lyricsDecision `json:"lyrics_decision_applied,omitempty"`

	LyricsRetryTS    int64 `json:"lyrics_retry_ts,omitempty"`
	LyricsRetryCount int   `json:"lyrics_retry_count,omitempty"`

	LyricsFillTS    int64 `json:"lyrics_fill_ts,omitempty"`
	LyricsFillCount int   `json:"lyrics_fill_count,omitempty"`

	ResolvedDurationSecs float64 `json:"resolved_duration_secs,omitempty"`

	LyricsScoringVersion int   `json:"lyrics_scoring_version,omitempty"`
	LyricsRescoreCount   int   `json:"lyrics_rescore_count,omitempty"`
	LyricsRescoreTS      int64 `json:"lyrics_rescore_ts,omitempty"`

	LyricsRescoreVersion int `json:"lyrics_rescore_version,omitempty"`

	PeripheralRetryCount int `json:"peripheral_retry_count,omitempty"`

	DurationSecs float64 `json:"duration_secs,omitempty"`

	LyricsTrSource string `json:"lyrics_tr_source,omitempty"`

	LyricsTrLang string `json:"lyrics_tr_lang,omitempty"`

	TranslationRetryCount int    `json:"translation_retry_count,omitempty"`
	TranslationTS         int64  `json:"translation_ts,omitempty"`
	TranslationLang       string `json:"translation_lang,omitempty"`

	ManualLyrics bool `json:"manual_lyrics,omitempty"`

	LyricsSourceChoice string `json:"lyrics_source_choice,omitempty"`

	ManualPickSHA string `json:"manual_pick_sha,omitempty"`

	Instrumental bool `json:"instrumental,omitempty"`

	TS int64 `json:"ts"`

	PeripheralTS int64 `json:"peripheral_ts,omitempty"`

	SpotifyTrackID string `json:"spotify_track_id,omitempty"`

	Unknown map[string]json.RawMessage `json:"-"`
}

func (e enrichEntry) fields() map[string]string {
	m := map[string]string{}
	put := func(k, v string) {
		if v != "" {
			m[k] = v
		}
	}
	put("cover_url", e.CoverURL)
	put("accent_color", e.AccentColor)
	put("netease_url", e.NeteaseURL)
	put("apple_music_url", e.AppleURL)
	put("qq_music_url", e.QQURL)
	put("spotify_url", e.spotifyLink())
	put("spotify_track_id", e.SpotifyTrackID)
	put("lyrics", e.Lyrics)
	put("lyrics_tr", e.LyricsTr)
	put("lyrics_roma", e.LyricsRoma)
	put("lyrics_yrc", e.LyricsYRC)
	put("canonical_artist", e.CanonicalArtist)
	put("cover_source", e.CoverSource)
	put("lyrics_source", e.LyricsSource)
	return m
}

const enrichPeripheralRetryInterval = 10 * time.Minute

var (
	enrichMu            sync.Mutex
	enrichCache         = map[string]enrichEntry{}
	enrichPath          string
	enrichDirty         bool
	enrichBaseline      map[string]enrichEntry
	enrichBaselinePath  string
	enrichBaselineReady bool
	enrichInflight      = map[string]bool{}

	enrichCancelFuncs = map[string]context.CancelFunc{}
	enrichNotify      chan struct{}
)

var enrichLooseMatchLogged = map[string]bool{}

func canonicalEnrichKey(key string) (string, bool) {
	loose := loosenEnrichKey(key)

	best := ""
	for existing, e := range enrichCache {
		if existing == key || loosenEnrichKey(existing) != loose {
			continue
		}
		if best == "" || betterEnrichEntry(e, enrichCache[best], existing, best) {
			best = existing
		}
	}
	if best == "" {
		return "", false
	}
	return best, true
}

func looseInflightKey(key string) (string, bool) {
	if enrichInflight[key] {
		return key, true
	}
	loose := loosenEnrichKey(key)
	for k := range enrichInflight {
		if loosenEnrichKey(k) == loose {
			return k, true
		}
	}
	return "", false
}

func loosenEnrichKey(key string) string {

	folded := strings.Map(func(r rune) rune {
		if isArtistCreditSep(r) {
			return '&'
		}
		return r
	}, toSimplified(key))
	return strings.ToLower(strings.ReplaceAll(folded, " ", ""))
}

func trackEnrichment(ctx context.Context, artist, title, album, bundleID string, durationSecs float64, isNewTrack, radio bool) map[string]string {
	if ctx == nil {
		ctx = context.Background()
	}
	if title == "" {
		return nil
	}

	if radioStationCard(radio, artist, title) {
		return nil
	}

	if isAdBreak(bundleID, artist, title, album) {
		return nil
	}

	setNativeLyricSourcesForPlayer(bundleID)
	key := enrichKey(artist, title, album)

	hintKey := key

	title = normEnrichTitle(title)

	coverAlbum := coverAlbumForTrack(context.Background(), artist, title, album, durationSecs)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {

		if alt, found := canonicalEnrichKey(key); found {

			if !enrichLooseMatchLogged[key] {
				enrichLooseMatchLogged[key] = true
				log.Printf("enrich: reusing existing entry %q for %q (loose match)", alt, key)
			}
			key, e, ok = alt, enrichCache[alt], true
		}
	}
	if ok && durationSecs > 0 {

		if rk, re, rok := resolveEnrichKeyForDuration(enrichCache, key, durationSecs); rk != key {
			log.Printf("enrich: %q duration mismatch (cached %.1fs vs actual %.1fs), using variant %q",
				key, e.DurationSecs, durationSecs, rk)
			key, e, ok = rk, re, rok
		}
	}
	if ok {

		spotifyHintDirty := applySpotifyTrackIDHintLocked(hintKey, &e)

		if applyRadioDurationHintLocked(hintKey, &e) {
			spotifyHintDirty = true
		}
		if spotifyHintDirty {
			enrichCache[key] = e
			enrichDirty = true
		}

		pinned := lyricsPinned(key)

		wrongDuration := observeWrongDuration(key,
			durationMismatch(e.ResolvedDurationSecs, durationSecs), durationSecs, time.Now().Unix())

		if needsLyricsFirstFill(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go retryLyricsUpgrade(ctx, key, artist, title, album, durationSecs, true)
		} else if isNewTrack && e.CoverSource != "device" && !enrichInflight[key] {
			enrichInflight[key] = true
			go applyDeviceCoverUpgrade(ctx, key, artist, title, album, bundleID)
		} else if (needsPeripheralBackfill(e, artist, album) ||
			(coverNeedsHintCheck(e, album, coverAlbum) && peripheralBackfillWindowOpen(e)) ||
			(motionCoverWorthBackfill(e, title, album) && peripheralBackfillWindowOpen(e))) && !enrichInflight[key] {

			enrichInflight[key] = true
			go backfillPeripheralFields(ctx, key, artist, title, album, durationSecs)
		} else if needsLyricsRescore(e, pinned, features.LyricsAutoUpgrade) && !enrichInflight[key] {
			enrichInflight[key] = true
			go rescoreLyrics(ctx, key, artist, title, album, durationSecs)
		} else if needsLyricsRetry(e, wrongDuration, pinned, features.LyricsAutoUpgrade) && !enrichInflight[key] {
			enrichInflight[key] = true
			go retryLyricsUpgrade(ctx, key, artist, title, album, durationSecs, false)
		} else if needsTranslationBackfill(e) && !enrichInflight[key] {
			enrichInflight[key] = true
			go backfillTranslation(ctx, key)
		}
		enrichMu.Unlock()
		if spotifyHintDirty {
			saveEnrichCache()
		}
		return e.fields()
	}

	if _, busy := looseInflightKey(key); !busy {
		enrichInflight[key] = true

		cancelCtx, cancel := context.WithCancel(ctx)
		enrichCancelFuncs[key] = cancel
		go resolveEnrichAsync(cancelCtx, key, artist, title, album, bundleID, durationSecs, isNewTrack)
	}
	enrichMu.Unlock()
	return nil
}

const peripheralBackfillMaxAttempts = 5

func needsPeripheralBackfill(e enrichEntry, artist, album string) bool {

	missingCanonical := e.CanonicalArtist == "" && len(artistCreditParts(artist)) <= 1

	missingQQMids := qqMidFromURL(e.QQURL) != "" && (e.QQAlbumMid == "" || e.QQSingerMid == "")

	missingNeteaseURL := e.NeteaseURL == "" && lyricSourceEnabled("netease") && !isNeteaseImpersonatorRidden(artist)

	missing := e.AccentColor == "" || e.AppleURL == "" || e.QQURL == "" || missingNeteaseURL ||
		isQQSearchFallbackURL(e.QQURL) || missingQQMids ||
		missingCanonical || coverNeedsAlbumCheck(e, album) ||
		coverCanUpgradeToVerifiedSiblingLocked(e, artist, album)
	if !missing {
		return false
	}
	return peripheralBackfillWindowOpen(e)
}

func peripheralBackfillWindowOpen(e enrichEntry) bool {
	if e.PeripheralRetryCount >= peripheralBackfillMaxAttempts {
		return false
	}
	base := e.PeripheralTS
	if base == 0 {
		base = e.TS
	}
	return time.Now().Unix()-base >= int64(enrichPeripheralRetryInterval/time.Second)
}

func preferAppleCoverOverNetease(neteaseAlbum, appleAlbum, appleCover, localAlbum string) bool {
	if appleCover == "" || localAlbum == "" {
		return false
	}
	return albumScore(neteaseAlbum, localAlbum) == 0 && albumScore(appleAlbum, localAlbum) > 0
}

func coverNeedsAlbumCheck(e enrichEntry, album string) bool {
	if album == "" || e.CoverSource != "netease" {
		return false
	}
	if e.CoverAlbum == "" {
		return true
	}
	return albumScore(e.CoverAlbum, album) < 200
}

func coverSwapAllowed(old, fresh enrichEntry, album string) bool {
	if fresh.CoverURL == "" {
		return false
	}

	if old.CoverSource == "device" {
		return deviceCoverUpgradable(old.CoverURL, fresh.CoverURL)
	}
	if old.CoverURL == "" || old.CoverSource == fresh.CoverSource {
		return true
	}

	if fresh.CoverSource == "device" {
		return true
	}
	if fresh.CoverSource == "qq" {

		return true
	}
	return fresh.NeteaseURL != "" && album != "" && albumScore(fresh.CoverAlbum, album) > 0
}

func siblingAlbumCover(artist, title, album string) (url, source string, albumVerified bool) {
	if album == "" {
		return "", "", false
	}
	self := enrichKey(artist, title, album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if u, src := siblingCoverLocked(self, artist, album, true); u != "" {
		return u, src, true
	}
	if u, src := siblingCoverLocked(self, artist, album, false); u != "" {
		return u, src, false
	}
	return "", "", false
}

func siblingCoverLocked(self, artist, album string, verifiedOnly bool) (url, source string) {
	keys := make([]string, 0, len(enrichCache))
	for k := range enrichCache {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if key == self {
			continue
		}
		e := enrichCache[key]
		if e.CoverURL == "" {
			continue
		}
		if verifiedOnly {
			if !coverSourceLendsAlbumIdentity(e.CoverSource) || albumScore(e.CoverAlbum, album) != 200 {
				continue
			}
		} else if e.CoverSource != "qq" {
			continue
		}
		a, _, al := splitEnrichKey(key)
		if al != album || !artistMatches(a, artist) {
			continue
		}
		return e.CoverURL, e.CoverSource
	}
	return "", ""
}

func coverSourceLendsAlbumIdentity(source string) bool {
	return source == "device"
}

func hasAlbumVerifiedSiblingCoverLocked(artist, album string) bool {
	if album == "" {
		return false
	}
	u, _ := siblingCoverLocked("", artist, album, true)
	return u != ""
}

func coverCanUpgradeToVerifiedSiblingLocked(e enrichEntry, artist, album string) bool {
	if album == "" || e.CoverSource == "device" || e.CoverURL == "" {
		return false
	}
	if albumScore(e.CoverAlbum, album) == 200 {
		return false
	}
	return hasAlbumVerifiedSiblingCoverLocked(artist, album)
}

func lyricSourcesWithCandidates(scored []scoredLyricCandidateResult) []string {
	return distinctLyricSources(scored, true)
}

func lyricSourcesResponded(scored []scoredLyricCandidateResult) []string {
	return distinctLyricSources(scored, false)
}

func distinctLyricSources(scored []scoredLyricCandidateResult, onlyValid bool) []string {
	seen := make([]string, 0, len(scored))
	for _, c := range scored {
		if onlyValid && c.Score < 0 {
			continue
		}
		dup := false
		for _, s := range seen {
			if s == c.Source {
				dup = true
				break
			}
		}
		if !dup {
			seen = append(seen, c.Source)
		}
	}
	return seen
}

func allEnabledLyricSourcesResponded(scored []scoredLyricCandidateResult) bool {
	responded := lyricSourcesResponded(scored)
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	for source, enabled := range features.LyricsSources {
		if !enabled {
			continue
		}
		if !containsString(responded, source) {
			return false
		}
	}
	return true
}

func rescoreDecidable(scored []scoredLyricCandidateResult, currentSource string, noCurrentLyrics bool) bool {
	if noCurrentLyrics {
		return true
	}
	if currentSource != "" && lyricSourceEnabled(currentSource) {
		return containsString(lyricSourcesResponded(scored), currentSource)
	}
	return allEnabledLyricSourcesResponded(scored)
}

func containsString(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

const (
	lyricsRetryInterval    = 6 * time.Hour
	lyricsRetryMaxAttempts = 3
)

const lyricsFillBaseInterval = 24 * time.Hour

func lyricsFillBackoff(count int) time.Duration {
	shift := count
	if shift > 4 {
		shift = 4
	}
	return lyricsFillBaseInterval << shift
}

func needsLyricsFirstFill(e enrichEntry) bool {
	if e.Lyrics != "" || e.ManualLyrics || e.Instrumental {
		return false
	}

	base := e.LyricsFillTS
	if e.TS > base {
		base = e.TS
	}
	interval := lyricsFillBackoff(e.LyricsFillCount)

	if (len(e.LyricsSourcesSkipped) > 0 || len(e.LyricsSourcesFailed) > 0) && e.LyricsFillCount == 0 {
		interval = lyricsFillSkippedRetryInterval
		if !anyLyricSourceCooling(e.LyricsSourcesSkipped) && !anyLyricSourceCooling(e.LyricsSourcesFailed) {
			interval = lyricsFillSkippedReadyRetryInterval
		}
	}
	return time.Now().Unix()-base >= int64(interval/time.Second)
}

const (
	lyricsFillSkippedRetryInterval      = 10 * time.Minute
	lyricsFillSkippedReadyRetryInterval = 30 * time.Second
)

func lyricsUpgradeBaseline(e enrichEntry, scored []scoredLyricCandidateResult) (baseline int, comparable bool) {

	if e.Lyrics == "" {
		return 0, true
	}
	if e.LyricsScoringVersion == lyricsScoringVersion {
		return e.LyricsScore, true
	}
	for i := range scored {
		if scored[i].Source == e.LyricsSource && scored[i].Lyrics == e.Lyrics {
			return scored[i].Score, true
		}
	}
	return 0, false
}

func durationMismatch(resolved, actual float64) bool {
	if resolved <= 0 || actual <= 0 {
		return false
	}
	larger := math.Max(resolved, actual)
	return math.Abs(resolved-actual)/larger > 0.12
}

func observeWrongDuration(key string, mismatch bool, actualDurationSecs float64, nowUnix int64) bool {
	if !mismatch {
		delete(wrongDurationSeen, key)
		return false
	}
	obs, ok := wrongDurationSeen[key]
	if !ok || math.Abs(obs.durationSecs-actualDurationSecs) > 1.0 ||
		nowUnix-obs.lastSeen > wrongDurationObsMaxGapSecs {
		wrongDurationSeen[key] = wrongDurationObs{durationSecs: actualDurationSecs, firstSeen: nowUnix, lastSeen: nowUnix}
		return false
	}
	obs.lastSeen = nowUnix
	wrongDurationSeen[key] = obs
	if nowUnix-obs.firstSeen < wrongDurationConfirmSecs {
		return false
	}
	delete(wrongDurationSeen, key)
	return true
}

const wrongDurationConfirmSecs = 30

const wrongDurationObsMaxGapSecs = 300

type wrongDurationObs struct {
	durationSecs float64
	firstSeen    int64
	lastSeen     int64
}

var wrongDurationSeen = map[string]wrongDurationObs{}

func needsLyricsRetry(e enrichEntry, wrongDuration, pinned, autoUpgrade bool) bool {
	if e.Lyrics == "" {
		return false
	}

	if !autoUpgrade {
		return false
	}

	if pinned {
		return false
	}

	nativeMissedOut := hasNativeLyricSource() && !isNativeLyricSource(e.LyricsSource) &&
		slices.ContainsFunc(e.LyricsSourcesSeen, func(s string) bool { return isNativeLyricSource(s) })

	if e.LyricsYRC != "" && !nativeMissedOut && !wrongDuration {
		return false
	}

	if e.ManualLyrics {
		return false
	}
	if e.LyricsRetryCount >= lyricsRetryMaxAttempts {
		return false
	}

	if nativeMissedOut || wrongDuration {
		return true
	}
	missing := false
	featuresMu.RLock()
	for source, enabled := range features.LyricsSources {
		if !enabled {
			continue
		}
		found := false
		for _, s := range e.LyricsSourcesSeen {
			if s == source {
				found = true
				break
			}
		}
		if !found {
			missing = true
			break
		}
	}
	featuresMu.RUnlock()
	if !missing {
		return false
	}

	base := e.LyricsRetryTS
	if e.TS > base {
		base = e.TS
	}
	return time.Now().Unix()-base >= int64(lyricsRetryInterval/time.Second)
}

func retryLyricsUpgrade(ctx context.Context, key, artist, title, album string, durationSecs float64, firstFill bool) {
	if ctx == nil {
		ctx = context.Background()
	}
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	sourceChoice := enrichCache[key].LyricsSourceChoice
	generation := enrichExternalGeneration[key]
	enrichMu.Unlock()

	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	_, scored := scoredLyricCandidates(roundCtx, artist, title, album, durationSecs)

	picked := pickLyricCandidatePreferring(scored, sourceChoice)
	seen := lyricSourcesWithCandidates(scored)

	enrichMu.Lock()

	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()

		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok || enrichExternalGeneration[key] != generation {

		return
	}
	if e.ManualLyrics {

		return
	}
	if firstFill {
		e.LyricsFillCount++
		e.LyricsFillTS = time.Now().Unix()
	} else {
		e.LyricsRetryCount++
		e.LyricsRetryTS = time.Now().Unix()
	}
	if len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	e.LyricsSourcesSkipped = round.skippedSources()
	e.LyricsSourcesFailed = round.failedSources()
	baseline, comparable := lyricsUpgradeBaseline(e, scored)
	upgraded := picked != nil && comparable && picked.Score > baseline
	path := lyricsDecisionPathUpgrade
	if firstFill {
		path = lyricsDecisionPathRefill
	}

	e.LyricsDecision = buildLyricsDecision(
		path, artist, title, album, durationSecs, scored, picked, upgraded)
	e.LyricsDecision.SourcesSkipped = e.LyricsSourcesSkipped
	e.LyricsDecision.QueriesTried = queries.queries()
	traceLyricsDecision(key, e.LyricsDecision)

	if upgraded || (picked != nil && picked.Source == e.LyricsSource && picked.Lyrics == e.Lyrics) {
		e.LyricsDecisionApplied = e.LyricsDecision
	}
	if upgraded {
		log.Printf("lyrics upgrade: %s  %s(%d) -> %s(%d)", key, e.LyricsSource, e.LyricsScore, picked.Source, picked.Score)
		e.Lyrics = picked.Lyrics
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		e.SongLanguage = songLanguageFromScored(scored)
		e.maybeGenerateRoma()
		lyricsChanged = true

		e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
	}

	if picked == nil && !e.Instrumental {
		for _, c := range scored {
			if c.Instrumental {
				e.Instrumental = true
				log.Printf("lyrics: %s marked instrumental by %s (no lyrics from any source)", key, c.Source)
				break
			}
		}
	}

	if picked == nil && !e.Instrumental && e.PlainLyrics == "" {
		if lyrics, source := plainTextFallbackFromScored(scored); lyrics != "" {
			e.PlainLyrics, e.PlainLyricsSource = lyrics, source
			log.Printf("lyrics: %s auto-adopted plain-text fallback from %s (no timed version from any source)", key, source)
		}
	}
	enrichCache[key] = e
	enrichDirty = true
}

func plainTextFallbackFromScored(scored []scoredLyricCandidateResult) (lyrics, source string) {
	for _, c := range scored {
		if c.PlainTextOnly && c.Lyrics != "" {
			return c.Lyrics, c.Source
		}
	}
	return "", ""
}

const (
	lyricsRescoreMaxAttempts   = 3
	lyricsRescoreDeferInterval = time.Hour
)

func needsLyricsRescore(e enrichEntry, pinned, autoUpgrade bool) bool {
	if e.Lyrics == "" || e.ManualLyrics || pinned {
		return false
	}

	if !autoUpgrade {
		return false
	}
	if e.LyricsScoringVersion >= lyricsScoringVersion {
		return false
	}

	if e.LyricsRescoreVersion != lyricsScoringVersion {
		return true
	}
	if e.LyricsRescoreCount >= lyricsRescoreMaxAttempts {
		return false
	}
	if e.LyricsRescoreTS > 0 &&
		time.Now().Unix()-e.LyricsRescoreTS < int64(lyricsRescoreDeferInterval/time.Second) {
		return false
	}
	return true
}

func rescoreLyrics(ctx context.Context, key, artist, title, album string, durationSecs float64) {
	if ctx == nil {
		ctx = context.Background()
	}
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	currentSource := enrichCache[key].LyricsSource
	sourceChoice := enrichCache[key].LyricsSourceChoice
	generation := enrichExternalGeneration[key]
	enrichMu.Unlock()

	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	_, scored := scoredLyricCandidates(roundCtx, artist, title, album, durationSecs)

	picked := pickLyricCandidatePreferring(scored, sourceChoice)

	decidable := rescoreDecidable(scored, currentSource, false)
	seen := lyricSourcesWithCandidates(scored)

	enrichMu.Lock()

	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()

		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok || enrichExternalGeneration[key] != generation {

		return
	}

	if e.ManualLyrics {
		return
	}

	if e.LyricsRescoreVersion != lyricsScoringVersion {
		e.LyricsRescoreCount = 0
		e.LyricsRescoreVersion = lyricsScoringVersion
	}
	e.LyricsRescoreCount++
	e.LyricsRescoreTS = time.Now().Unix()
	if len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	e.LyricsSourcesSkipped = round.skippedSources()
	e.LyricsSourcesFailed = round.failedSources()

	if decidable {
		e.LyricsDecision = buildLyricsDecision(
			lyricsDecisionPathRescore, artist, title, album, durationSecs, scored, picked,
			picked != nil && picked.Lyrics != e.Lyrics)
		e.LyricsDecision.SourcesSkipped = e.LyricsSourcesSkipped
		e.LyricsDecision.QueriesTried = queries.queries()
		traceLyricsDecision(key, e.LyricsDecision)

		if picked != nil {
			e.LyricsDecisionApplied = e.LyricsDecision
		}
	}
	switch {
	case !decidable:
		log.Printf("lyrics rescore deferred: %s  current source %q did not answer this round (responded: %v)",
			key, currentSource, lyricSourcesResponded(scored))
	case picked == nil:

		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		log.Printf("lyrics rescore: %s  no valid candidate under v%d, keeping %s", key, lyricsScoringVersion, e.LyricsSource)
	default:
		if picked.Lyrics != e.Lyrics {
			log.Printf("lyrics rescore: %s  %s(v%d) -> %s(%d)", key, e.LyricsSource, e.LyricsScoringVersion, picked.Source, picked.Score)
			e.Lyrics = picked.Lyrics
			e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
			e.SongLanguage = songLanguageFromScored(scored)
			e.maybeGenerateRoma()
			lyricsChanged = true

			e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
		}
		if picked.Source != e.LyricsSource {

			lyricsChanged = true
		}
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
	}
	enrichCache[key] = e
	enrichDirty = true
}

func resolveEnrichAsync(ctx context.Context, key, artist, title, album, bundleID string, durationSecs float64, isNewTrack bool) {
	enrichMu.Lock()
	generation := enrichExternalGeneration[key]
	enrichMu.Unlock()
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)

		if cancel, ok := enrichCancelFuncs[key]; ok {
			cancel()
			delete(enrichCancelFuncs, key)
		}
		enrichMu.Unlock()
	}()

	roundStat := beginNetworkRound()
	deviceCoverURL := deviceCoverURLIfFresh(ctx, isNewTrack, bundleID, artist, title)
	e := resolveTrackEnrichment(ctx, artist, title, album, durationSecs, deviceCoverURL)

	enrichMu.Lock()
	applySpotifyTrackIDHintLocked(key, &e)
	enrichMu.Unlock()
	e.TS = time.Now().Unix()

	if ctx.Err() != nil {

		e.LyricsSourcesSkipped = nil
		e.LyricsSourcesFailed = nil
		commitEnrichEntry(key, e, generation)
		return
	}

	attempts, failures := roundStat()
	networkDown := roundLooksNetworkDown(attempts, failures)
	switch {
	case networkDown:

		markCollectorNetworkDown()
	case attempts > 0:

		clearCollectorNetworkDown()
	}

	hasRealQQURL := e.QQURL != "" && !isQQSearchFallbackURL(e.QQURL)
	if e.CoverURL == "" && e.Lyrics == "" && e.AppleURL == "" && !hasRealQQURL && e.NeteaseURL == "" {

		if lyricsRoundConfirmsNoResult(attempts, failures) {
			commitEnrichEntry(key, e, generation)
		}
		return
	}
	commitEnrichEntry(key, e, generation)
}

func commitEnrichEntry(key string, e enrichEntry, generation uint64) {
	enrichMu.Lock()
	if enrichExternalGeneration[key] != generation {
		enrichMu.Unlock()
		return
	}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	exportLyricsFiles()

	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

func applyDeviceCoverUpgrade(ctx context.Context, key, artist, title, album, bundleID string) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	deviceCoverURL := deviceCoverURLIfFresh(ctx, true, bundleID, artist, title)
	if deviceCoverURL == "" {
		return
	}
	accent := dominantColor(ctx, deviceCoverURL)

	enrichMu.Lock()
	existing, exists := enrichCache[key]
	enrichMu.Unlock()
	if !exists || existing.CoverURL == deviceCoverURL {
		return
	}

	if !deviceCoverOverridesCandidate(ctx, deviceCoverURL, existing.CoverURL) {
		return
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok || e.CoverURL == deviceCoverURL {

		enrichMu.Unlock()
		return
	}
	e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = deviceCoverURL, "device", album, accent
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

func backfillPeripheralFields(ctx context.Context, key, artist, title, album string, durationSecs float64) {
	if ctx == nil {
		ctx = context.Background()
	}
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()

	fresh := resolveTrackEnrichment(ctx, artist, title, album, durationSecs, "")

	coverAlbum := coverAlbumForTrack(ctx, artist, title, album, durationSecs)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {

		enrichMu.Unlock()
		return
	}

	if coverSwapAllowed(e, fresh, coverAlbum) {
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor =
			fresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor
	}

	e.CoverURL = qqCoverAtEdge(e.CoverURL, qqCoverMaxEdge)
	if fresh.AppleURL != "" {
		e.AppleURL = fresh.AppleURL
	}
	if fresh.QQURL != "" {

		if !isQQSearchFallbackURL(fresh.QQURL) || isQQSearchFallbackURL(e.QQURL) {
			e.QQURL = fresh.QQURL
		}
	}

	if e.QQAlbumMid == "" || e.QQSingerMid == "" {
		if songMid := qqMidFromURL(e.QQURL); songMid != "" {
			if albumMid, singerMid := qqSongCatalogMids(ctx, songMid); albumMid != "" || singerMid != "" {
				if e.QQAlbumMid == "" {
					e.QQAlbumMid = albumMid
				}
				if e.QQSingerMid == "" {
					e.QQSingerMid = singerMid
				}
			}
		}
	}
	if fresh.SpotifyURL != "" {
		e.SpotifyURL = fresh.SpotifyURL
	}

	if fresh.MotionCoverURL != "" {
		e.MotionCoverURL = fresh.MotionCoverURL
		e.MotionPreviewURL = fresh.MotionPreviewURL
	}

	if fresh.MotionCoverChecked {
		e.MotionCoverChecked = true
	}
	if fresh.NeteaseURL != "" {
		e.NeteaseURL = fresh.NeteaseURL
	}
	if e.CanonicalArtist == "" {
		e.CanonicalArtist = fresh.CanonicalArtist
	}
	if e.DurationSecs <= 0 {
		e.DurationSecs = fresh.DurationSecs
	}

	e.PeripheralTS = time.Now().Unix()

	e.PeripheralRetryCount++
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}

func resolveTrackEnrichment(ctx context.Context, artist, title, album string, durationSecs float64, deviceCoverURL string) enrichEntry {

	artist, title, album = toSimplified(artist), toSimplified(title), toSimplified(album)
	var e enrichEntry

	var ne neteaseInfo
	var scored []scoredLyricCandidateResult

	roundCtx, round := withLyricSourceRound(ctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	ne, scored = scoredLyricCandidates(roundCtx, artist, title, album, durationSecs)

	e.CoverURL = ne.Cover
	if e.CoverURL != "" {
		e.CoverSource = "netease"
		e.CoverAlbum = ne.Album
	}
	e.NeteaseURL = ne.SongURL

	e.CanonicalArtist = canonicalArtistViaMusicBrainz(ctx, artist)

	coverAlbum := album
	if coverAlbum == "" {
		coverAlbum = appleAlbumHintSync(ctx, artist, title, durationSecs,
			coverAlbumCorroboration(artist, title, album, e.CanonicalArtist, pickLyricCandidate(scored)))
	}
	appleMatch := appleMusicMatchCached(ctx, artist, title, coverAlbum)
	if e.CoverURL == "" && appleMatch.cover != "" {
		e.CoverURL = appleMatch.cover
		e.CoverSource = "apple"
		e.CoverAlbum = appleMatch.album
	}

	if e.CoverSource == "netease" &&
		preferAppleCoverOverNetease(e.CoverAlbum, appleMatch.album, appleMatch.cover, coverAlbum) {
		e.CoverURL, e.CoverSource, e.CoverAlbum = appleMatch.cover, "apple", appleMatch.album
	}

	if e.CoverURL == "" || (coverAlbum != "" && albumScore(e.CoverAlbum, coverAlbum) < 200) {

		qqCover, _ := qqCoverFallback(ctx, artist, title, coverAlbum)
		if qqCover != "" {

			e.CoverURL, e.CoverSource, e.CoverAlbum = qqCover, "qq", ""
		}

	}

	if coverAlbum != "" && albumScore(e.CoverAlbum, coverAlbum) < 200 {
		if url, source, albumVerified := siblingAlbumCover(artist, title, coverAlbum); url != "" {
			e.CoverURL, e.CoverSource = url, source

			if albumVerified {

				e.CoverAlbum = album
			} else {
				e.CoverAlbum = ""
			}
		}
	}
	if deviceCoverURL != "" {

		if deviceCoverOverridesCandidate(ctx, deviceCoverURL, e.CoverURL) {
			e.CoverURL, e.CoverSource, e.CoverAlbum = deviceCoverURL, "device", album
		}
	}
	if e.CanonicalArtist == "" {

		e.CanonicalArtist = resolveGenericArtistCanonicalName(ctx, artist)
	}
	if e.CoverURL != "" {

		e.AccentColor = dominantColor(ctx, e.CoverURL)
	}

	e.AppleURL = appleMatch.url
	e.QQURL = qqMusicURL(ctx, artist, title, album, durationSecs)

	e.QQAlbumMid, e.QQSingerMid = qqSongCatalogMids(ctx, qqMidFromURL(e.QQURL))
	if title != "" {
		e.SpotifyURL = "https://open.spotify.com/search/" + neturl.QueryEscape(artist+" "+title)
	}
	e.DurationSecs = durationSecs

	e.LyricsSourcesSeen = lyricSourcesWithCandidates(scored)
	e.LyricsSourcesResponded = lyricSourcesResponded(scored)
	e.LyricsSourcesSkipped = round.skippedSources()
	e.LyricsSourcesFailed = round.failedSources()
	picked := pickLyricCandidate(scored)

	e.LyricsDecision = buildLyricsDecision(
		lyricsDecisionPathFirstResolve, artist, title, album, durationSecs, scored, picked, picked != nil)
	e.LyricsDecision.SourcesSkipped = e.LyricsSourcesSkipped
	e.LyricsDecision.QueriesTried = queries.queries()

	traceLyricsDecision(artist+"|"+title+"|"+album, e.LyricsDecision)
	if picked != nil {

		e.LyricsDecisionApplied = e.LyricsDecision
		e.Lyrics = picked.Lyrics
		e.LyricsSource = picked.Source
		e.LyricsScore = picked.Score
		e.LyricsScoringVersion = lyricsScoringVersion
		e.ResolvedDurationSecs = durationSecs
		e.LyricsTr, e.LyricsRoma, e.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		e.SongLanguage = songLanguageFromScored(scored)
		e.maybeGenerateRoma()

		e.LyricsTrLang, e.LyricsTrSource = picked.LyricsTrLang, ""
	} else {

		for _, c := range scored {
			if c.Instrumental {
				e.Instrumental = true
				break
			}
		}

		if !e.Instrumental && e.PlainLyrics == "" {
			if lyrics, source := plainTextFallbackFromScored(scored); lyrics != "" {
				e.PlainLyrics, e.PlainLyricsSource = lyrics, source
			}
		}
	}
	e.fillMotionCover(ctx, title, album)
	return e
}

func (e *enrichEntry) fillMotionCover(ctx context.Context, title, album string) {
	if e.MotionCoverChecked || e.MotionCoverURL != "" {
		return
	}

	albumID, viaAnchor := appleCatalogAlbumIDFor(title, album)
	if !viaAnchor {
		albumID = motionCoverAlbumIDFromAppleURL(e.AppleURL)
	}
	if albumID <= 0 {
		return
	}
	mc, done := motionCoverFor(ctx, albumID)
	if !done {

		return
	}
	if mc.Master == "" {

		e.MotionCoverChecked = true
		return
	}

	e.MotionCoverChecked = true
	if !motionCoverMatchesCover(ctx, mc.PreviewFrame, e.CoverURL) {
		return
	}
	e.MotionCoverURL = mc.Master
	e.MotionPreviewURL = mc.PreviewFrame
}

func pickLyricCandidatePreferring(scored []scoredLyricCandidateResult, sourceChoice string) *scoredLyricCandidateResult {
	if sourceChoice == "" {
		return pickLyricCandidate(scored)
	}
	filtered := make([]scoredLyricCandidateResult, 0, len(scored))
	for _, c := range scored {
		if c.Source == sourceChoice {
			filtered = append(filtered, c)
		}
	}
	return pickLyricCandidate(filtered)
}

func pickLyricCandidate(scored []scoredLyricCandidateResult) *scoredLyricCandidateResult {
	if features.LyricsSourceMode == lyricsModePriority {
		for _, source := range features.LyricsSourceOrder {
			if !lyricSourceEnabled(source) {
				continue
			}
			for i := range scored {
				if scored[i].Source == source && scored[i].Score >= 0 {
					return &scored[i]
				}
			}
		}
		return nil
	}
	var picked *scoredLyricCandidateResult
	bestScore := -1
	for i := range scored {
		if !lyricSourceEnabled(scored[i].Source) {
			continue
		}
		if scored[i].Score < 0 || scored[i].Score <= bestScore {
			continue
		}
		bestScore = scored[i].Score
		picked = &scored[i]
	}
	return picked
}

type scoredLyricCandidateResult struct {
	Source        string `json:"source"`
	Lyrics        string `json:"lyrics"`
	LyricsTr      string `json:"lyrics_tr,omitempty"`
	LyricsTrLang  string `json:"lyrics_tr_lang,omitempty"`
	LyricsRoma    string `json:"lyrics_roma,omitempty"`
	LyricsYRC     string `json:"lyrics_yrc,omitempty"`
	HasWordTiming bool   `json:"has_word_timing"`
	Score         int    `json:"score"`

	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`

	ConsensusPeers []string `json:"consensus_peers,omitempty"`

	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`

	Language string `json:"language,omitempty"`

	Title    string `json:"title,omitempty"`
	Artist   string `json:"artist,omitempty"`
	Album    string `json:"album,omitempty"`
	CoverURL string `json:"cover_url,omitempty"`

	RetryMethod  string `json:"retry_method,omitempty"`
	RetriedTitle string `json:"retried_title,omitempty"`

	Instrumental bool `json:"instrumental,omitempty"`

	PlainTextOnly bool `json:"plain_text_only,omitempty"`

	BakedTranslationLines int `json:"baked_translation_lines,omitempty"`
}

const lyricSearchDeadline = 20 * time.Second

func scoredLyricCandidates(ctx context.Context, artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return scoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})
}

func scoredLyricCandidatesStreaming(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	ne, results := fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, onUpdate)

	if !hasUsableLyricCandidate(results) {
		if splitArtist, splitTitle, ok := albumHintTitleSplit(title); ok {
			log.Printf("lyrics: %q - %q has no usable candidate, retrying as title-split identity %q - %q", artist, title, splitArtist, splitTitle)
			splitCtx := withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)
			splitNe, splitResults := scoredLyricCandidatesStreaming(splitCtx, splitArtist, splitTitle, album, durationSecs, onUpdate)
			if hasUsableLyricCandidate(splitResults) {
				log.Printf("lyrics: title-split identity fallback succeeded: original=%q - %q identity=%q - %q candidates=%d sources=%v",
					artist, title, splitArtist, splitTitle, len(splitResults), lyricSourcesWithCandidates(splitResults))
				return splitNe, splitResults
			}
		}
	}

	rescue := !hasUsableLyricCandidate(results)
	romaRetry := needsRomanizationRetry(results)
	missing := lyricSourcesWorthAliasRetry(results)
	if rescue || romaRetry || len(missing) > 0 {

		var titleSearchIdentities []string
		if rescue {
			titleSearchIdentities = appleTitleSearchIdentities(ctx, artist, title, durationSecs)
		}
		altIdentities := dedupeArtistIdentities(
			appleCatalogSearchIdentities(artist, title, album),
			appleStorefrontArtistIdentities(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results)),
			titleSearchIdentities,
			retryArtistIdentities(ctx, artist))
		if len(altIdentities) > 0 {
			switch {
			case rescue:
				log.Printf("lyrics: %q has no usable candidate yet, trying alt identities: %v", artist, altIdentities)
			case romaRetry:
				log.Printf("lyrics: %q has no romanization signal yet, trying alt identities: %v", artist, altIdentities)
			default:
				log.Printf("lyrics: %q left %v without a usable candidate, trying alt identities for them: %v", artist, missing, altIdentities)
			}
		}
		romaTried := false
		for _, alt := range altIdentities {

			var only []string
			if !rescue && !romaRetry {
				only = missing
			}
			if romaRetry {
				romaTried = true
			}

			aliasReason := lyricQueryReasonAliasMissing
			switch {
			case rescue:
				aliasReason = lyricQueryReasonAliasRescue
			case romaRetry:
				aliasReason = lyricQueryReasonAliasRoma
			}
			altCtx := withLyricQueryReason(withLyricSourceOnly(ctx, only), aliasReason)

			aliasUpdate := func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
				onUpdate(vne, mergeLyricCandidateRounds(artist, title, album, durationSecs, results, vres), done, total)
			}
			altNe, altResults := fetchScoredLyricCandidatesStreaming(altCtx, alt, title, album, durationSecs, aliasUpdate)

			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			if hasUsableLyricCandidate(altResults) {
				log.Printf("lyrics: artist alias fallback succeeded: original_artist=%q alias=%q title=%q candidates=%d sources=%v",
					artist, alt, title, len(altResults), lyricSourcesWithCandidates(altResults))

				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}

				results = merged
			} else if len(results) == 0 && len(altResults) > 0 {

				results = merged
				if ne.Cover == "" && altNe.Cover != "" {
					ne = altNe
				}
			}

			rescue = !hasUsableLyricCandidate(results)
			romaRetry = !romaTried && needsRomanizationRetry(results)
			missing = lyricSourcesWorthAliasRetry(results)
			if !rescue && !romaRetry && len(missing) == 0 {
				break
			}
		}
	}

	targetSources := 2
	if n := enabledLyricSourceCount(); n < targetSources {
		targetSources = n
	}
	if primary := lyricPrimaryQueryArtist(artist); primary != "" && usableLyricSourceCount(results) < targetSources {
		tryVariant := func(alt string) {

			mergedUpdate := func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
				onUpdate(vne, mergeLyricCandidateRounds(artist, title, album, durationSecs, results, vres), done, total)
			}
			variantCtx := withLyricQueryReason(ctx, lyricQueryReasonPrimaryVar)
			altNe, altResults := fetchScoredLyricCandidatesStreaming(variantCtx, alt, title, album, durationSecs, mergedUpdate)
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)
			if usableLyricSourceCount(merged) <= usableLyricSourceCount(results) {
				return
			}
			log.Printf("lyrics: primary-artist variant added candidates: original_artist=%q variant=%q title=%q usable_sources=%d->%d",
				artist, alt, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
			results = merged

			if ne.Cover == "" && altNe.Cover != "" {
				ne.Cover, ne.Album, ne.AlbumID = altNe.Cover, altNe.Album, altNe.AlbumID
			}
			if ne.SongURL == "" && altNe.SongURL != "" {
				ne.SongURL = altNe.SongURL
			}
		}
		tryVariant(primary)
		if usableLyricSourceCount(results) < targetSources {

			for _, alt := range retryArtistIdentities(ctx, primary) {
				tryVariant(alt)
				if usableLyricSourceCount(results) >= targetSources {
					break
				}
			}
		}
	}

	if usableLyricSourceCount(results) < targetSources {

		titleArtists := []string{artist}
		if aliases := retryArtistIdentities(ctx, artist); len(aliases) > 0 && normLoose(aliases[0]) != normLoose(artist) {
			titleArtists = append(titleArtists, aliases[0])
		}

		var albumTitle, searchTitle, albumWinArtist, searchWinArtist string
		var albumDiff, searchDiff float64
		var albumOK, searchOK bool
		for _, ta := range titleArtists {
			if t, d, ok := retryTitleFromAlbumDetailed(ctx, ta, album, durationSecs); ok && (!albumOK || d < albumDiff) {
				albumTitle, albumDiff, albumOK, albumWinArtist = t, d, true, ta
			}
			if t, d, ok := retryTitleFromArtistSearchDetailed(ctx, ta, title, durationSecs); ok && (!searchOK || d < searchDiff) {
				searchTitle, searchDiff, searchOK, searchWinArtist = t, d, true, ta
			}
		}

		storefrontTitle := appleStorefrontCanonicalTitle(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results))
		storefrontOK := storefrontTitle != "" && normLoose(storefrontTitle) != normLoose(title)

		var correctedTitle, retryMethod, titleArtist string
		switch {

		case storefrontOK && artistScriptDiffers(title, storefrontTitle):
			correctedTitle, retryMethod, titleArtist = storefrontTitle, lyricQueryReasonTitleStorefront, artist
		case albumOK && (!searchOK || albumDiff <= searchDiff):
			correctedTitle, retryMethod, titleArtist = albumTitle, "title-from-album", albumWinArtist
		case searchOK:
			correctedTitle, retryMethod, titleArtist = searchTitle, "title-from-artist-search", searchWinArtist

		case storefrontOK:
			correctedTitle, retryMethod, titleArtist = storefrontTitle, lyricQueryReasonTitleStorefront, artist
		}
		log.Printf("lyrics: title-reverse-lookup: titleArtists=%v albumTitle=%q albumDiff=%v albumOK=%v albumWinArtist=%q searchTitle=%q searchDiff=%v searchOK=%v searchWinArtist=%q storefrontTitle=%q storefrontOK=%v -> corrected=%q method=%q titleArtist=%q",
			titleArtists, albumTitle, albumDiff, albumOK, albumWinArtist, searchTitle, searchDiff, searchOK, searchWinArtist, storefrontTitle, storefrontOK, correctedTitle, retryMethod, titleArtist)
		if correctedTitle != "" && normLoose(correctedTitle) != normLoose(title) {
			titleUpdate := func(vne neteaseInfo, vres []scoredLyricCandidateResult, done, total int) {
				onUpdate(vne, mergeLyricCandidateRounds(artist, title, album, durationSecs, results, vres), done, total)
			}

			titleCtx := withLyricQueryReason(ctx, retryMethod)
			altNe, altResults := fetchScoredLyricCandidatesStreaming(titleCtx, titleArtist, correctedTitle, album, durationSecs, titleUpdate)

			for i := range altResults {
				altResults[i].RetryMethod = retryMethod
				altResults[i].RetriedTitle = correctedTitle
			}
			merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, altResults)

			if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
				log.Printf("lyrics: %s fallback added candidates: original_title=%q corrected_title=%q artist=%q usable_sources=%d->%d",
					retryMethod, title, correctedTitle, titleArtist, usableLyricSourceCount(results), usableLyricSourceCount(merged))
			}
			results = merged
			if ne.Cover == "" && altNe.Cover != "" {
				ne.Cover, ne.Album, ne.AlbumID = altNe.Cover, altNe.Album, altNe.AlbumID
			}
			if ne.SongURL == "" && altNe.SongURL != "" {
				ne.SongURL = altNe.SongURL
			}
		}
	}
	return ne, results
}

func hasUsableLyricCandidate(scored []scoredLyricCandidateResult) bool {
	for _, c := range scored {
		if c.Score >= 0 {
			return true
		}
	}
	return false
}

func lyricSourcesWorthAliasRetry(scored []scoredLyricCandidateResult) []string {
	usable := map[string]bool{}
	for _, c := range scored {
		if c.Score >= 0 && !c.Instrumental {
			usable[c.Source] = true
		}
	}
	transport := lyricSourceBreakerShared.transportFailureCodes()
	var out []string
	for _, s := range lyricSourceNames {
		if !lyricSourceEnabled(s) || usable[s] || transport[s] != "" {
			continue
		}
		switch s {
		case "lyricfind":
			if ytmusicLastFailureReasonNow() != "" {
				continue
			}
		case "musixmatch":
			if musixmatchLastFailureReasonNow() != "" {
				continue
			}
		case "deezer":

			if deezerLastFailureReasonNow() != "" {
				continue
			}
		}
		out = append(out, s)
	}
	return out
}

func usableLyricSourceCount(scored []scoredLyricCandidateResult) int {
	seen := map[string]bool{}
	for _, c := range scored {
		if c.Score >= 0 && !c.Instrumental &&
			lyricSourceEnabled(c.Source) {
			seen[c.Source] = true
		}
	}
	return len(seen)
}

func lyricCandidateFromScored(r scoredLyricCandidateResult) lyricCandidate {
	tr, roma := usableValueAdd(r.Lyrics, r.LyricsTr, r.LyricsTrLang, r.LyricsRoma, features.LyricsTranslationLanguage)
	return lyricCandidate{
		source:                     r.Source,
		lyrics:                     r.Lyrics,
		wordTimingYRC:              r.LyricsYRC,
		hasWordTiming:              r.HasWordTiming,
		hasUsableTranslation:       tr,
		hasUsableRomanization:      roma,
		sourceReportedDurationSecs: r.SourceReportedDurationSecs,
		title:                      r.Title,
		artist:                     r.Artist,
		album:                      r.Album,
		cover:                      r.CoverURL,
		language:                   r.Language,
		plainTextOnly:              r.PlainTextOnly,
	}
}

func mergeLyricCandidateRounds(artist, title, album string, durationSecs float64, base, extra []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	chosen := map[string]scoredLyricCandidateResult{}
	var order []string
	var instrumental *scoredLyricCandidateResult
	for _, r := range base {
		if r.Instrumental {
			if instrumental == nil {
				rr := r
				instrumental = &rr
			}
			continue
		}
		if _, ok := chosen[r.Source]; !ok {
			chosen[r.Source] = r
			order = append(order, r.Source)
		}
	}
	for _, r := range extra {
		if r.Instrumental {
			if instrumental == nil {
				rr := r
				instrumental = &rr
			}
			continue
		}
		cur, ok := chosen[r.Source]
		if !ok {
			chosen[r.Source] = r
			order = append(order, r.Source)
			continue
		}
		if cur.Score < 0 && r.Score >= 0 {
			chosen[r.Source] = r
		}
	}

	ordered := make([]string, 0, len(order))
	inNames := map[string]bool{}
	for _, s := range lyricSourceNames {
		if _, ok := chosen[s]; ok {
			ordered = append(ordered, s)
			inNames[s] = true
		}
	}
	for _, s := range order {
		if !inNames[s] {
			ordered = append(ordered, s)
		}
	}
	cands := make([]lyricCandidate, 0, len(ordered))
	for _, s := range ordered {
		cands = append(cands, lyricCandidateFromScored(chosen[s]))
	}

	applyLanguageVersionVerdicts(title, album, durationSecs, cands)
	corroborated := corroboratedEndings(cands, durationSecs)
	consensusPeers := contentConsensusPeers(artist, title, cands, durationSecs)
	out := make([]scoredLyricCandidateResult, 0, len(ordered)+1)

	hasRealFromMarkerSource := false
	for i, s := range ordered {
		r := chosen[s]
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, cands[i], corroborated[s], len(consensusPeers[s]))
		r.ConsensusPeers = consensusPeers[s]
		if instrumental != nil && s == instrumental.Source {
			hasRealFromMarkerSource = true
		}
		out = append(out, r)
	}
	if instrumental != nil && !hasRealFromMarkerSource {
		out = append(out, *instrumental)
	}

	applyWordTimingTitleOverride(out)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	return out
}

func fetchScoredLyricCandidates(ctx context.Context, artist, title, album string, durationSecs float64) (neteaseInfo, []scoredLyricCandidateResult) {
	return fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})
}

type lyricSearchUpdateFunc func(ne neteaseInfo, results []scoredLyricCandidateResult, done, total int)

var lyricSourceNames = []string{"netease", "qq", "kugou", "lrclib", "musixmatch", "amll", "lyricfind", "kuwo", "migu", "deezer"}

func enabledLyricSourceCount() int {
	n := 0
	for _, s := range lyricSourceNames {
		if lyricSourceEnabled(s) {
			n++
		}
	}
	return n
}

type lyricSourceResult struct {
	source                  string
	ne                      neteaseInfo
	lyr, yrc, tr, roma      string
	matchTitle, matchArtist string
	matchAlbum, matchCover  string
	srcDur                  float64

	language string

	instrumental bool

	plainOnly bool

	amll amllResult
}

var lyricSourceResultTap func(lyricSourceResult)

var lyricSearchItemsTap func(source, artist, title, album string, durationSecs float64, items any)

func rankLyricSourceResults(artist, title, album string, durationSecs float64, raw map[string]lyricSourceResult) []scoredLyricCandidateResult {

	raw = decodeLyricSourceEntities(raw)
	ne := raw["netease"].ne
	qq, kugou, lrclib, mx, lf, kuwo := raw["qq"], raw["kugou"], raw["lrclib"], raw["musixmatch"], raw["lyricfind"], raw["kuwo"]
	qqLyr, qqYRC, qqTr, qqRoma, qqTitle, qqArtist, qqAlbum, qqCover, qqDur, qqLang := qq.lyr, qq.yrc, qq.tr, qq.roma, qq.matchTitle, qq.matchArtist, qq.matchAlbum, qq.matchCover, qq.srcDur, qq.language
	qqInstrumental := qq.instrumental
	kugouLyr, kugouYRC, kugouTr, kugouRoma, kugouTitle, kugouArtist, kugouAlbum, kugouCover, kugouDur, kugouLang := kugou.lyr, kugou.yrc, kugou.tr, kugou.roma, kugou.matchTitle, kugou.matchArtist, kugou.matchAlbum, kugou.matchCover, kugou.srcDur, kugou.language
	lrclibLyr, lrclibTitle, lrclibArtist, lrclibAlbum, lrclibDur := lrclib.lyr, lrclib.matchTitle, lrclib.matchArtist, lrclib.matchAlbum, lrclib.srcDur
	lrclibInstrumental := lrclib.instrumental
	lrclibPlainOnly := lrclib.plainOnly
	mxLyr, mxYRC, mxTr, mxTitle, mxArtist, mxAlbum, mxCover, mxDur := mx.lyr, mx.yrc, mx.tr, mx.matchTitle, mx.matchArtist, mx.matchAlbum, mx.matchCover, mx.srcDur
	mxPlainOnly := mx.plainOnly
	mxInstrumental := mx.instrumental
	lfLyr, lfTitle, lfArtist, lfAlbum, lfCover, lfDur := lf.lyr, lf.matchTitle, lf.matchArtist, lf.matchAlbum, lf.matchCover, lf.srcDur
	kuwoLyr, kuwoTitle, kuwoArtist, kuwoAlbum, kuwoCover, kuwoDur := kuwo.lyr, kuwo.matchTitle, kuwo.matchArtist, kuwo.matchAlbum, kuwo.matchCover, kuwo.srcDur
	migu := raw["migu"]
	miguLyr, miguTr, miguTitle, miguArtist, miguAlbum, miguCover := migu.lyr, migu.tr, migu.matchTitle, migu.matchArtist, migu.matchAlbum, migu.matchCover
	dz := raw["deezer"]
	dzLyr, dzTitle, dzArtist, dzAlbum, dzCover, dzDur, dzPlainOnly := dz.lyr, dz.matchTitle, dz.matchArtist, dz.matchAlbum, dz.matchCover, dz.srcDur, dz.plainOnly
	amll := raw["amll"].amll
	appleCover := raw["applecover"].matchCover

	coverOrFallback := func(own string) string {
		if own != "" {
			return own
		}
		return appleCover
	}

	foreignSong := !containsHan(artist) && !containsHan(title)
	bakedLines := map[string]int{}
	ne.Lyrics, ne.Trans, ne.YRC, bakedLines["netease"] = adoptBakedTranslation(ne.Lyrics, ne.Trans, ne.YRC, foreignSong, true)
	qqLyr, qqTr, qqYRC, bakedLines["qq"] = adoptBakedTranslation(qqLyr, qqTr, qqYRC, foreignSong, true)
	kugouLyr, kugouTr, kugouYRC, bakedLines["kugou"] = adoptBakedTranslation(kugouLyr, kugouTr, kugouYRC, foreignSong, true)
	mxLyr, _, mxYRC, bakedLines["musixmatch"] = adoptBakedTranslation(mxLyr, "", mxYRC, foreignSong, false)
	lrclibLyr, _, _, bakedLines["lrclib"] = adoptBakedTranslation(lrclibLyr, "", "", foreignSong, false)
	lfLyr, _, _, bakedLines["lyricfind"] = adoptBakedTranslation(lfLyr, "", "", foreignSong, false)

	var kuwoTr string
	kuwoLyr, kuwoTr, _, bakedLines["kuwo"] = adoptBakedTranslation(kuwoLyr, "", "", foreignSong, true)
	amll.lrc, _, amll.yrc, bakedLines["amll"] = adoptBakedTranslation(amll.lrc, "", amll.yrc, foreignSong, false)
	var candidates []lyricCandidate
	if ne.Lyrics != "" {

		neTr, neRoma := usableValueAdd(ne.Lyrics, ne.Trans, "zh", ne.Roma, features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "netease", lyrics: ne.Lyrics, wordTimingYRC: usableYRC(ne.Lyrics, ne.YRC), hasWordTiming: usableWordTiming(ne.Lyrics, ne.YRC), hasUsableTranslation: neTr, hasUsableRomanization: neRoma, sourceReportedDurationSecs: ne.DurationSecs, title: ne.Title, artist: ne.Artist, album: ne.Album, cover: coverOrFallback(ne.Cover)})
	}
	if qqLyr != "" {

		qqUsableTr, qqUsableRoma := usableValueAdd(qqLyr, qqTr, "zh", qqRoma, features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "qq", lyrics: qqLyr, wordTimingYRC: usableYRC(qqLyr, qqYRC), hasWordTiming: usableWordTiming(qqLyr, qqYRC), hasUsableTranslation: qqUsableTr, hasUsableRomanization: qqUsableRoma, sourceReportedDurationSecs: qqDur, title: qqTitle, artist: qqArtist, album: qqAlbum, cover: coverOrFallback(qqCover), language: qqLang})
	}
	if kugouLyr != "" {

		kugouUsableTr, kugouUsableRoma := usableValueAdd(kugouLyr, kugouTr, "zh", kugouRoma, features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kugou", lyrics: kugouLyr, wordTimingYRC: usableYRC(kugouLyr, kugouYRC), hasWordTiming: usableWordTiming(kugouLyr, kugouYRC), hasUsableTranslation: kugouUsableTr, hasUsableRomanization: kugouUsableRoma, sourceReportedDurationSecs: kugouDur, title: kugouTitle, artist: kugouArtist, album: kugouAlbum, cover: coverOrFallback(kugouCover), language: kugouLang})
	}
	if mxLyr != "" {
		mxUsableTr, _ := usableValueAdd(mxLyr, mxTr, features.LyricsTranslationLanguage, "", features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "musixmatch", lyrics: mxLyr, wordTimingYRC: usableYRC(mxLyr, mxYRC), hasWordTiming: usableWordTiming(mxLyr, mxYRC), hasUsableTranslation: mxUsableTr, sourceReportedDurationSecs: mxDur, title: mxTitle, artist: mxArtist, album: mxAlbum, cover: coverOrFallback(mxCover), plainTextOnly: mxPlainOnly})
	}
	if lrclibLyr != "" {
		candidates = append(candidates, lyricCandidate{source: "lrclib", lyrics: lrclibLyr, sourceReportedDurationSecs: lrclibDur, title: lrclibTitle, artist: lrclibArtist, album: lrclibAlbum, cover: coverOrFallback(""), plainTextOnly: lrclibPlainOnly})
	}
	if lfLyr != "" {

		candidates = append(candidates, lyricCandidate{source: "lyricfind", lyrics: lfLyr, sourceReportedDurationSecs: lfDur, title: lfTitle, artist: lfArtist, album: lfAlbum, cover: coverOrFallback(lfCover)})
	}
	if kuwoLyr != "" {

		kuwoUsableTr, _ := usableValueAdd(kuwoLyr, kuwoTr, "zh", "", features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "kuwo", lyrics: kuwoLyr, hasUsableTranslation: kuwoUsableTr, sourceReportedDurationSecs: kuwoDur, title: kuwoTitle, artist: kuwoArtist, album: kuwoAlbum, cover: coverOrFallback(kuwoCover)})
	}
	if miguLyr != "" {

		miguUsableTr, _ := usableValueAdd(miguLyr, miguTr, "zh", "", features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{source: "migu", lyrics: miguLyr, hasUsableTranslation: miguUsableTr, title: miguTitle, artist: miguArtist, album: miguAlbum, cover: coverOrFallback(miguCover)})
	}
	if dzLyr != "" {

		candidates = append(candidates, lyricCandidate{source: "deezer", lyrics: dzLyr, sourceReportedDurationSecs: dzDur, title: dzTitle, artist: dzArtist, album: dzAlbum, cover: coverOrFallback(dzCover), plainTextOnly: dzPlainOnly})
	}
	if !amll.empty() {

		amllTr, _ := usableValueAdd(amll.lrc, amll.tr, features.LyricsTranslationLanguage, "", features.LyricsTranslationLanguage)
		candidates = append(candidates, lyricCandidate{
			source: "amll", lyrics: amll.lrc,
			wordTimingYRC: usableYRC(amll.lrc, amll.yrc), hasWordTiming: usableWordTiming(amll.lrc, amll.yrc),
			hasUsableTranslation: amllTr,
			title:                title, artist: artist, album: album, cover: coverOrFallback(""),
		})
	}

	rehangCandidateTimelines(candidates, durationSecs)

	applyLanguageVersionVerdicts(title, album, durationSecs, candidates)
	corroborated := corroboratedEndings(candidates, durationSecs)

	consensusPeers := contentConsensusPeers(artist, title, candidates, durationSecs)

	var instrumentalMarker *scoredLyricCandidateResult
	if lrclibLyr == "" && lrclibInstrumental {
		instrumentalMarker = &scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	} else if qqLyr == "" && qqInstrumental {

		instrumentalMarker = &scoredLyricCandidateResult{Source: "qq", Score: -1, Instrumental: true}
	} else if ne.Lyrics == "" && ne.PureMusic {

		instrumentalMarker = &scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
	} else if mxLyr == "" && mxInstrumental {

		instrumentalMarker = &scoredLyricCandidateResult{Source: "musixmatch", Score: -1, Instrumental: true}
	}

	results := make([]scoredLyricCandidateResult, 0, len(candidates))
	for _, c := range candidates {
		r := scoredLyricCandidateResult{
			Source:                     c.source,
			Lyrics:                     c.lyrics,
			LyricsYRC:                  c.wordTimingYRC,
			HasWordTiming:              c.hasWordTiming,
			SourceReportedDurationSecs: c.sourceReportedDurationSecs,
			Title:                      c.title,
			Artist:                     c.artist,
			Album:                      c.album,
			CoverURL:                   c.cover,
			Language:                   c.language,
			PlainTextOnly:              c.plainTextOnly,
			BakedTranslationLines:      bakedLines[c.source],
		}
		r.Score, r.ScoreTerms = scoreLyricCandidateDetailed(
			artist, title, album, durationSecs, c, corroborated[c.source], len(consensusPeers[c.source]))
		r.ConsensusPeers = consensusPeers[c.source]

		switch c.source {
		case "netease":

			if c.hasUsableTranslation {
				r.LyricsTr = ne.Trans
				r.LyricsTrLang = "zh"
			}
			if c.hasUsableRomanization {
				r.LyricsRoma = ne.Roma
			}
		case "musixmatch":

			if c.hasUsableTranslation {
				r.LyricsTr = mxTr

				r.LyricsTrLang = features.LyricsTranslationLanguage
			}
		case "amll":

			if c.hasUsableTranslation {
				r.LyricsTr = amll.tr
				r.LyricsTrLang = features.LyricsTranslationLanguage
			}
		case "qq":

			if c.hasUsableTranslation {
				r.LyricsTr = qqTr
				r.LyricsTrLang = "zh"
			}
			if c.hasUsableRomanization {
				r.LyricsRoma = qqRoma
			}
		case "kuwo":

			if c.hasUsableTranslation {
				r.LyricsTr = kuwoTr
				r.LyricsTrLang = "zh"
			}
		case "kugou":

			if c.hasUsableTranslation {
				r.LyricsTr = kugouTr
				r.LyricsTrLang = "zh"
			}
			if c.hasUsableRomanization {
				r.LyricsRoma = kugouRoma
			}
		case "migu":

			if c.hasUsableTranslation {
				r.LyricsTr = miguTr
				r.LyricsTrLang = "zh"
			}
		}

		if len(c.timelineRemap) > 0 {
			if tr, ok := remapLRCTimestamps(r.LyricsTr, c.timelineRemap); ok {
				r.LyricsTr = tr
			}
			if roma, ok := remapLRCTimestamps(r.LyricsRoma, c.timelineRemap); ok {
				r.LyricsRoma = roma
			}
		}
		results = append(results, r)
	}
	if instrumentalMarker != nil {
		results = append(results, *instrumentalMarker)
	}

	applyWordTimingTitleOverride(results)

	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	return results
}

type lyricSourceSkip int

const (
	lyricSourceQuery lyricSourceSkip = iota
	lyricSourceSkipDisabled
	lyricSourceSkipCooling
)

func lyricSourceSkipFor(source string, enabled func(string) bool, plan lyricSourceRoundPlan) lyricSourceSkip {
	if !enabled(source) {
		return lyricSourceSkipDisabled
	}
	if _, cooling := plan[source]; cooling {
		return lyricSourceSkipCooling
	}
	return lyricSourceQuery
}

func fetchScoredLyricCandidatesStreaming(ctx context.Context, artist, title, album string, durationSecs float64, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {

	resultsCh := make(chan lyricSourceResult, len(lyricSourceNames)+1)

	lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), sortedLyricSourceOnly(ctx))

	breakerPlan := lyricSourceBreakerShared.planRound(lyricSourceNames, lyricSourceEnabled)
	round := lyricSourceRoundFrom(ctx)

	only := lyricSourceOnlyFrom(ctx)
	skipSource := func(source string) bool {

		if only != nil && !only[source] {
			return true
		}
		switch lyricSourceSkipFor(source, lyricSourceEnabled, breakerPlan) {
		case lyricSourceSkipDisabled:
			return true
		case lyricSourceSkipCooling:
			round.markSkipped(source)
			log.Printf("lyrics: source %s skipped this round, cooling down for another %s", source, breakerPlan[source].Round(time.Second))
			return true
		}
		return false
	}

	neteaseIDCh := make(chan string, 1)
	qqIDCh := make(chan string, 1)

	go func() {
		if skipSource("netease") {
			neteaseIDCh <- ""
			resultsCh <- lyricSourceResult{source: "netease"}
			return
		}
		info := neteaseLookup(ctx, artist, title, album, durationSecs)
		if info.SongID > 0 {
			neteaseIDCh <- strconv.FormatInt(info.SongID, 10)
		} else {
			neteaseIDCh <- ""
		}
		resultsCh <- lyricSourceResult{source: "netease", ne: info}
	}()
	go func() {
		if skipSource("qq") {
			qqIDCh <- ""
			resultsCh <- lyricSourceResult{source: "qq"}
			return
		}

		match := qqMusicMatchCached(ctx, artist, title, album, durationSecs)
		qqMid := qqMidFromURL(match.url)
		var lyr, yrc, tr, roma string
		var qqDur float64
		var qqInstrumental bool
		if qqMid != "" {
			qqLyr := qqLyric(ctx, qqMid)
			lyr, qqInstrumental = qqLyr.lrc, qqLyr.instrumental

			qrc := qqQRCLyric(ctx, qqMid, artist, title, album, durationSecs)
			yrc, tr, roma = qrc.yrc, qrc.tr, qrc.roma

			lyr = attachKanaLine(lyr, qrc.kana)

			qqDur = match.interval
			if qqDur <= 0 {
				qqDur = qqSongMetaCachedOnly(qqMid).interval
			}
		}
		qqIDCh <- qqMid

		qqLang := qqCanonicalLanguage(qqSongMetaCachedOnly(qqMid).language)

		var qqCover string
		if qqMid != "" {
			qqCover, _ = qqSongCoverAndSinger(ctx, qqMid)
		}
		resultsCh <- lyricSourceResult{source: "qq", lyr: lyr, yrc: yrc, tr: tr, roma: roma, matchTitle: match.title, matchArtist: match.artist, matchAlbum: match.album, matchCover: qqCover, srcDur: qqDur, language: qqLang, instrumental: qqInstrumental}
	}()
	go func() {

		var neteaseID, qqID string
		select {
		case neteaseID = <-neteaseIDCh:
		case <-ctx.Done():
			resultsCh <- lyricSourceResult{source: "amll"}
			return
		}
		select {
		case qqID = <-qqIDCh:
		case <-ctx.Done():
			resultsCh <- lyricSourceResult{source: "amll"}
			return
		}
		if skipSource("amll") {
			resultsCh <- lyricSourceResult{source: "amll"}
			return
		}
		resultsCh <- lyricSourceResult{source: "amll", amll: amllLyric(ctx, neteaseID, qqID)}
	}()
	go func() {
		if skipSource("kugou") {
			resultsCh <- lyricSourceResult{source: "kugou"}
			return
		}
		r := kugouLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "kugou", lyr: r.lrc, yrc: r.yrc, tr: r.tr, roma: r.roma, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, language: r.language}
	}()
	go func() {
		if skipSource("lrclib") {
			resultsCh <- lyricSourceResult{source: "lrclib"}
			return
		}
		r := lrclibLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "lrclib", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, srcDur: r.durationSecs, instrumental: r.instrumental, plainOnly: r.plainOnly}
	}()
	go func() {
		if skipSource("musixmatch") {
			resultsCh <- lyricSourceResult{source: "musixmatch"}
			return
		}
		r := musixmatchLyric(ctx, artist, title, durationSecs, features.LyricsTranslationLanguage)
		resultsCh <- lyricSourceResult{source: "musixmatch", lyr: r.lrc, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly, instrumental: r.instrumental}
	}()
	go func() {
		if skipSource("lyricfind") {
			resultsCh <- lyricSourceResult{source: "lyricfind"}
			return
		}

		r := ytmusicLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "lyricfind", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
	}()
	go func() {
		if skipSource("kuwo") {
			resultsCh <- lyricSourceResult{source: "kuwo"}
			return
		}
		r := kuwoLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "kuwo", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
	}()
	go func() {
		if skipSource("migu") {
			resultsCh <- lyricSourceResult{source: "migu"}
			return
		}

		r := miguLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "migu", lyr: r.lyrics, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover}
	}()
	go func() {
		if skipSource("deezer") {
			resultsCh <- lyricSourceResult{source: "deezer"}
			return
		}

		r := deezerLyric(ctx, artist, title, album, durationSecs)
		resultsCh <- lyricSourceResult{source: "deezer", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	}()
	go func() {

		resultsCh <- lyricSourceResult{source: "applecover", matchCover: appleMusicMatchCached(ctx, artist, title, album).cover}
	}()

	raw := map[string]lyricSourceResult{}

	scoreAndSort := func() []scoredLyricCandidateResult {
		return rankLyricSourceResults(artist, title, album, durationSecs, raw)
	}

	deadline := time.After(lyricSearchDeadline)

	doneSources := map[string]bool{}
	totalSources := enabledLyricSourceCount()
	enabledDone := func() int {
		n := 0
		for _, s := range lyricSourceNames {
			if doneSources[s] && lyricSourceEnabled(s) {
				n++
			}
		}
		return n
	}

collect:
	for i := 0; i < len(lyricSourceNames)+1; i++ {
		select {
		case r := <-resultsCh:
			doneSources[r.source] = true
			raw[r.source] = r
			if lyricSourceResultTap != nil {
				lyricSourceResultTap(r)
			}
			onUpdate(raw["netease"].ne, scoreAndSort(), enabledDone(), totalSources)
		case <-deadline:
			for _, source := range lyricSourceNames {
				if !doneSources[source] && lyricSourceEnabled(source) && (only == nil || only[source]) {
					round.markFailed(source)
				}
			}
			log.Printf("lyrics: search deadline (%s) hit for artist=%q title=%q, proceeding with %d/%d sources back", lyricSearchDeadline, artist, title, i, totalSources)
			break collect
		case <-ctx.Done():

			break collect
		}
	}

	return raw["netease"].ne, scoreAndSort()
}
