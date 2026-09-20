package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func runBackfillLastfmCLI(args []string) {
	fs := flag.NewFlagSet("backfill-lastfm", flag.ExitOnError)
	dryRun := fs.Bool("dry-run", false, "count what would be submitted without sending anything")
	timeoutSecs := fs.Int("timeout", 600, "overall timeout in seconds")
	_ = fs.Parse(args)

	if configDir() == "" {
		emitBackfillOutcome(backfillOutcome{AbortedReason: "cannot resolve home directory"})
		return
	}
	cfgDir := configDir()
	cfgPath := filepath.Join(cfgDir, "config.json")

	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	listenLogPath = filepath.Join(cfgDir, clientName+"-listens.jsonl")

	cfg, err := loadConfig(cfgPath)
	if err != nil {
		emitBackfillOutcome(backfillOutcome{AbortedReason: fmt.Sprintf("load config: %v", err)})
		return
	}

	lastfmCollapsePath = filepath.Join(cfgDir, clientName+"-lastfm-collapse.json")

	lastfmFeedNudgePath = filepath.Join(cfgDir, clientName+"-lastfm-feed-nudge")

	scrobbler := newLastfmScrobbler(
		cfg.LastfmScrobbleAPIKey, cfg.LastfmScrobbleSecret, cfg.LastfmScrobbleSessionKey)
	if scrobbler != nil {

		scrobbler.collapse = newLastfmArtistCollapser(cfg.lastfmBridgeAPIKey())
	}

	if scrobbler == nil && !*dryRun {
		emitBackfillOutcome(backfillOutcome{AbortedReason: "last.fm not connected"})
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*timeoutSecs)*time.Second)
	defer cancel()
	emitBackfillOutcome(runBackfill(ctx, scrobbler, *dryRun))
}

func emitBackfillOutcome(out backfillOutcome) {
	enc := json.NewEncoder(os.Stdout)
	_ = enc.Encode(out)
}
