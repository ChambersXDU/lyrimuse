package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"path/filepath"
)

func runTestLyricSourcesCLI(args []string) {
	fs := flag.NewFlagSet("test-lyric-sources", flag.ExitOnError)
	only := fs.String("source", "", "只测这一个源(留空 = 测所有已启用的源)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("test-lyric-sources: %v", err)
	}

	if configDir() != "" {
		cfgPath := filepath.Join(configDir(), "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))
	}

	targets := enabledLyricSourceNames()
	if *only != "" {
		targets = []string{*only}
	}
	if len(targets) == 0 {

		return
	}
	wanted := make(map[string]bool, len(targets))
	for _, t := range targets {
		wanted[t] = true
	}
	reported := make(map[string]bool, len(targets))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	allReported := func() bool {
		for _, t := range targets {
			if !reported[t] {
				return false
			}
		}
		return true
	}

	enc := json.NewEncoder(os.Stdout)
	emitResult := func(source, status, reasonCode string) {
		if reported[source] {
			return
		}
		reported[source] = true
		if err := enc.Encode(lyricSourceTestResult{
			Source: source, Status: status, ReasonCode: reasonCode,
			NetworkLooksDown: networkLooksDown(),
		}); err != nil {
			log.Fatalf("test-lyric-sources: encode result: %v", err)
		}
	}

	scanForPositives := func(results []scoredLyricCandidateResult) {
		for _, src := range lyricSourcesResponded(results) {
			if wanted[src] && !reported[src] {

				emitResult(src, "ok", "")
			}
		}
		if allReported() {
			cancel()
		}
	}

	runProbe := func(artist, title, album string) {

		onUpdate := func(_ neteaseInfo, results []scoredLyricCandidateResult, _ int, _ int) {
			scanForPositives(results)
		}
		_, results := scoredLyricCandidatesStreaming(
			ctx, toSimplified(artist), toSimplified(title), toSimplified(album), 0, onUpdate)
		scanForPositives(results)
	}

	runProbe("梦然", "少年", "")

	if !allReported() {
		runProbe("The Beatles", "Yesterday", "Help!")
	}

	down := networkLooksDown()
	for _, src := range targets {
		if reported[src] {
			continue
		}

		reasonCode := lyricTestReasonNoResponse
		status := "warn"
		if down {
			status, reasonCode = "fail", lyricTestReasonNetworkDown
		} else {

			var reason string
			switch src {
			case "lyricfind":
				reason = ytmusicLastFailureReasonNow()
			case "musixmatch":
				reason = musixmatchLastFailureReasonNow()
			case "deezer":

				reason = deezerLastFailureReasonNow()
			case "netease":

				if !neteaseSawSuccessNow() {
					reason = neteaseLastFailureReasonNow()
				}
			}
			if reason != "" {
				reasonCode = reason
			}
		}
		emitResult(src, status, reasonCode)
	}
}

type lyricSourceTestResult struct {
	Source string `json:"source"`

	Status string `json:"status"`

	ReasonCode       string `json:"reasonCode"`
	NetworkLooksDown bool   `json:"networkLooksDown"`
}
