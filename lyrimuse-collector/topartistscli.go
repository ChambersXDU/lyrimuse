package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"path/filepath"
	"time"
)

func runTopArtistsCLI(args []string) {
	fs := flag.NewFlagSet("top-artists", flag.ExitOnError)
	period := fs.String("period", "overall", "7day|1month|3month|6month|12month|overall")
	limit := fs.Int("limit", 10, "merged entries to output")

	allPeriods := fs.Bool("all-periods", false, "fetch 7day/1month/12month/overall in one run")
	mbBudget := fs.Int("mb-budget", 0, "resolve up to N uncached artist identities via MusicBrainz (0 = cache only)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("top-artists: %v", err)
	}

	if *limit < 1 {
		*limit = 10
	}
	switch *period {
	case "7day", "1month", "3month", "6month", "12month", "overall":
	default:
		log.Fatalf("top-artists: invalid -period %q", *period)
	}

	if configDir() == "" {
		log.Fatalf("top-artists: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfg, err := loadConfig(filepath.Join(configDir(), "config.json"))
	if err != nil {
		log.Fatalf("top-artists: load config: %v", err)
	}
	if cfg.LastfmUser == "" || cfg.lastfmBridgeAPIKey() == "" {
		log.Fatal("top-artists: lastfm_user / api key not configured")
	}

	loadArtistIdentityCache(filepath.Join(configDir(), clientName+"-artist-identity-cache.json"))

	loadArtistAliasCache(filepath.Join(configDir(), clientName+"-artist-alias-cache.json"))
	loadQQArtistNameCache(filepath.Join(configDir(), clientName+"-qq-artist-name-cache.json"))
	artistCanonicalCacheOnly = *mbBudget <= 0
	resolve := budgetedArtistIdentity(*mbBudget)
	defer saveArtistIdentityCache()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if *allPeriods {
		periods := []string{"7day", "1month", "12month", "overall"}
		type periodResult struct {
			period  string
			entries []lastfmChartEntry
			err     error
		}
		ch := make(chan periodResult, len(periods))
		for _, pd := range periods {
			go func(pd string) {
				pool := topArtistsFetchPool
				if pool < *limit*3 {
					pool = *limit * 3
				}
				entries, err := lastfmTopArtistsPeriod(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), pd, pool)
				ch <- periodResult{pd, entries, err}
			}(pd)
		}
		out := map[string][]topArtistEntry{}
		for range periods {
			r := <-ch
			if r.err != nil {

				log.Printf("top-artists: period %s failed: %v", r.period, r.err)
				continue
			}
			merged := mergeAliasedArtistsResolved(r.entries, resolve)
			if len(merged) > *limit {
				merged = merged[:*limit]
			}
			rows := make([]topArtistEntry, 0, len(merged))
			for _, e := range merged {
				rows = append(rows, topArtistEntry{Name: e.Name, PlayCount: e.PlayCount})
			}
			out[r.period] = rows
		}
		if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
			log.Fatalf("top-artists: encode: %v", err)
		}
		return
	}

	pool := topArtistsFetchPool
	if pool < *limit*3 {
		pool = *limit * 3
	}
	entries, err := lastfmTopArtistsPeriod(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), *period, pool)
	if err != nil {
		log.Fatalf("top-artists: fetch: %v", err)
	}
	merged := mergeAliasedArtistsResolved(entries, resolve)
	if len(merged) > *limit {
		merged = merged[:*limit]
	}

	out := make([]topArtistEntry, 0, len(merged))
	for _, e := range merged {
		out = append(out, topArtistEntry{Name: e.Name, PlayCount: e.PlayCount})
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		log.Fatalf("top-artists: encode: %v", err)
	}
}
