package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

func runSearchLyricsCLI(args []string) {
	fs := flag.NewFlagSet("search-lyrics", flag.ExitOnError)
	artist := fs.String("artist", "", "track artist")
	title := fs.String("title", "", "track title")
	album := fs.String("album", "", "track album")
	duration := fs.Float64("duration", 0, "track duration in seconds (for duration-match scoring)")

	pick := fs.Bool("pick", false, "also decide a winner with the automatic resolve rules (pickLyricCandidate)")

	currentSource := fs.String("current-source", "", "the lyric source in effect now (for the -pick decidability guard)")

	if err := fs.Parse(args); err != nil {
		log.Fatalf("search-lyrics: %v", err)
	}
	if *title == "" {
		fmt.Fprintln(os.Stderr, "search-lyrics: -title is required")
		os.Exit(2)
	}

	if configDir() != "" {
		cfgPath := filepath.Join(configDir(), "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))

		loadArtistAliasCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-alias-cache.json"))

		loadMBPrimaryNameCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-primary-cache.json"))

		loadAppleCatalogCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-apple-catalog-cache.json"))

		loadAppleStorefrontArtistCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-apple-storefront-artist-cache.json"))

		loadAppleStorefrontTitleCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-apple-storefront-title-cache.json"))

		loadQQArtistNameCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-qq-artist-name-cache.json"))

		loadEnrichCacheReadOnly(filepath.Join(filepath.Dir(cfgPath), clientName+"-enrich-cache.json"))

	}

	sArtist, sTitle, sAlbum := toSimplified(*artist), toSimplified(*title), toSimplified(*album)

	effectiveDuration := *duration
	if effectiveDuration <= 0 {
		if m := appleMusicMatchCached(context.Background(), sArtist, sTitle, sAlbum); m.durationSecs > 0 {
			log.Printf("search-lyrics: duration missing from caller, recovered %.3fs from Apple catalog", m.durationSecs)
			effectiveDuration = m.durationSecs
		}
	}
	enc := json.NewEncoder(os.Stdout)
	var appleTitle, appleAlbum string

	var finalPick *searchLyricsPick

	round, lastDone := 1, 0
	emit := func(_ neteaseInfo, results []scoredLyricCandidateResult, done, total int) {
		if done < lastDone {
			round++
		}
		lastDone = done

		update := searchLyricsUpdate{
			Candidates:               filterEnabledLyricSources(results),
			NetworkLooksDown:         networkLooksDown(),
			SourcesDone:              done,
			SourcesTotal:             total,
			Round:                    round,
			AppleTitle:               appleTitle,
			AppleAlbum:               appleAlbum,
			SourceFailureReasonCodes: lyricSourceFailureReasons(results),
			Pick:                     finalPick,
		}
		for _, r := range results {
			if r.Instrumental {
				update.Instrumental = true
				update.LegacyLrclibInstrumental = true
			}
		}
		if err := enc.Encode(update); err != nil {
			log.Fatalf("search-lyrics: encode results: %v", err)
		}
	}

	go retryArtistIdentities(context.Background(), sArtist)

	searchCtx, queries := withLyricQueryLog(context.Background())
	_, results := scoredLyricCandidatesStreaming(searchCtx, sArtist, sTitle, sAlbum, effectiveDuration, emit)

	appleMatch := appleMusicMatchCachedOnly(sArtist, sTitle, sAlbum)
	appleTitle, appleAlbum = appleMatch.title, appleMatch.album

	noCurrentLyrics := false
	if *pick && configDir() != "" {
		cachePath := filepath.Join(configDir(), clientName+"-enrich-cache.json")
		if empty, known := lyricsEmptyInCacheFile(cachePath, *artist, *title, *album); known {
			noCurrentLyrics = empty
		}
	}
	if *pick {

		picked := pickLyricCandidate(results)
		p := &searchLyricsPick{
			ScoringVersion: lyricsScoringVersion,

			Decidable:            rescoreDecidable(results, *currentSource, noCurrentLyrics),
			SourcesSeen:          lyricSourcesWithCandidates(results),
			SourcesResponded:     lyricSourcesResponded(results),
			ResolvedDurationSecs: effectiveDuration,
			Mode:                 features.LyricsSourceMode,
		}
		if picked != nil {
			p.Winner = picked.Source
			p.WinnerScore = picked.Score
		}

		if p.Decidable {
			d := buildLyricsDecision(lyricsDecisionPathManualRematch, sArtist, sTitle, sAlbum, effectiveDuration,
				results, picked, picked != nil && picked.Source != *currentSource)
			d.QueriesTried = queries.queries()
			if raw, err := json.Marshal(d); err == nil {
				p.DecisionJSON = string(raw)
			}
		}
		finalPick = p
	}

	emit(neteaseInfo{}, results, enabledLyricSourceCount(), enabledLyricSourceCount())
}

type searchLyricsUpdate struct {
	Candidates       []scoredLyricCandidateResult `json:"candidates"`
	NetworkLooksDown bool                         `json:"networkLooksDown"`

	SourcesDone  int `json:"sourcesDone"`
	SourcesTotal int `json:"sourcesTotal"`

	Round int `json:"round"`

	AppleTitle string `json:"appleTitle,omitempty"`
	AppleAlbum string `json:"appleAlbum,omitempty"`

	SourceFailureReasonCodes map[string]string `json:"sourceFailureReasonCodes,omitempty"`

	Instrumental bool `json:"instrumental,omitempty"`

	LegacyLrclibInstrumental bool `json:"lrclibInstrumental,omitempty"`

	Pick *searchLyricsPick `json:"pick,omitempty"`
}

type searchLyricsPick struct {
	Winner      string `json:"winner,omitempty"`
	WinnerScore int    `json:"winnerScore"`

	ScoringVersion int `json:"scoringVersion"`

	Decidable            bool     `json:"decidable"`
	SourcesSeen          []string `json:"sourcesSeen,omitempty"`
	SourcesResponded     []string `json:"sourcesResponded,omitempty"`
	ResolvedDurationSecs float64  `json:"resolvedDurationSecs,omitempty"`

	Mode string `json:"mode,omitempty"`

	DecisionJSON string `json:"decisionJSON,omitempty"`
}

func filterEnabledLyricSources(results []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	filtered := make([]scoredLyricCandidateResult, 0, len(results))
	for _, r := range results {
		if r.Instrumental {
			continue
		}
		if !lyricSourceEnabled(r.Source) {
			continue
		}
		filtered = append(filtered, r)
	}
	return filtered
}

func lyricSourceFailureReasons(results []scoredLyricCandidateResult) map[string]string {
	return lyricSourceFailureReasonsWith(results, lyricSourceBreakerShared.transportFailureCodes(),
		lyricSourceEnabled, amllSkippedForMissingIDsNow())
}

func lyricSourceFailureReasonsWith(results []scoredLyricCandidateResult, transport map[string]string,
	enabled func(string) bool, amllSkippedForMissingIDs bool) map[string]string {
	responded := lyricSourcesResponded(results)
	reasons := make(map[string]string)
	check := func(source string, reasonFn func() string) {
		if containsString(responded, source) {
			return
		}
		if r := reasonFn(); r != "" {
			reasons[source] = r
		}
	}

	if !neteaseSawSuccessNow() {
		check("netease", neteaseLastFailureReasonNow)
	}
	check("musixmatch", musixmatchLastFailureReasonNow)
	check("lyricfind", ytmusicLastFailureReasonNow)

	check("deezer", deezerLastFailureReasonNow)

	for source, code := range transport {
		if containsString(responded, source) || !enabled(source) {
			continue
		}
		if _, has := reasons[source]; has {
			continue
		}
		reasons[source] = code
	}

	if amllSkippedForMissingIDs && enabled("amll") && !containsString(responded, "amll") {
		if _, has := reasons["amll"]; !has && transport["netease"] != "" && transport["qq"] != "" {
			reasons["amll"] = lyricFailureReasonUpstreamUnreachable
		}
	}
	if len(reasons) == 0 {
		return nil
	}
	return reasons
}

func lyricsEmptyInCacheFile(path, artist, title, album string) (empty bool, known bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return false, false
	}
	var m map[string]struct {
		Lyrics string `json:"lyrics"`
	}
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return false, false
	}
	e, ok := m[enrichKey(artist, title, album)]
	if !ok {
		return true, true
	}
	return e.Lyrics == "", true
}
