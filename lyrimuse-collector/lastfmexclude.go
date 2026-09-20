package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

func resolveLastfmExcludedBundles(raw []string) map[string]bool {
	out := map[string]bool{}
	for _, b := range raw {
		b = strings.TrimSpace(b)
		if b == "" {
			continue
		}
		out[b] = true
	}
	return out
}

func lastfmExcluded(bundleID string) bool {
	excluded := currentLastfmExcludedBundles()
	if bundleID == "" || len(excluded) == 0 {
		return false
	}
	if excluded[bundleID] {
		return true
	}
	if owner, ok := mediaProxyOwners[bundleID]; ok && excluded[owner] {
		return true
	}
	return false
}

var (

	lastfmExcludePath  string
	lastfmExcludeMu    sync.Mutex
	lastfmExcludeSet   map[string]bool
	lastfmExcludeMTime time.Time
	lastfmExcludeSize  int64
	lastfmExcludeRead  bool
)

func setLastfmExcludePath(path string) {
	lastfmExcludeMu.Lock()
	defer lastfmExcludeMu.Unlock()
	lastfmExcludePath = path
	lastfmExcludeRead = false
}

func currentLastfmExcludedBundles() map[string]bool {
	lastfmExcludeMu.Lock()
	defer lastfmExcludeMu.Unlock()
	if lastfmExcludePath == "" {
		return features.LastfmExcludedBundles
	}
	st, err := os.Stat(lastfmExcludePath)
	if err != nil {

		lastfmExcludeSet, lastfmExcludeRead = nil, true
		lastfmExcludeMTime, lastfmExcludeSize = time.Time{}, 0
		return nil
	}
	if !lastfmExcludeRead || !st.ModTime().Equal(lastfmExcludeMTime) || st.Size() != lastfmExcludeSize {
		lastfmExcludeSet = readLastfmExcludedBundles(lastfmExcludePath)
		lastfmExcludeMTime, lastfmExcludeSize, lastfmExcludeRead = st.ModTime(), st.Size(), true
	}
	return lastfmExcludeSet
}

func readLastfmExcludedBundles(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var f struct {
		LastfmExcludedBundles []string `json:"lastfm_excluded_bundles"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		log.Printf("lastfm exclude: cannot parse %s, treating as empty: %v", path, err)
		return nil
	}
	return resolveLastfmExcludedBundles(f.LastfmExcludedBundles)
}
