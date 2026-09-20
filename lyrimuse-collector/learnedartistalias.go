package main

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
)

func learnedSourceArtistAlias(artist string) string {
	prefix := cleanMediaTag(artist)
	if prefix == "" {
		return ""
	}
	prefix += "|"
	self := normLoose(artist)

	enrichMu.Lock()
	var names []string
	distinct := map[string]bool{}
	for k, e := range enrichCache {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		name := winningCandidateArtist(e)
		if name == "" || normLoose(name) == self {
			continue
		}
		names = append(names, name)
		distinct[normLoose(name)] = true
	}
	enrichMu.Unlock()

	if len(distinct) != 1 {
		return ""
	}
	sort.Strings(names)
	return names[0]
}

func winningCandidateArtist(e enrichEntry) string {
	d := e.LyricsDecisionApplied
	if d == nil || d.Winner == "" {
		return ""
	}
	for _, c := range d.Candidates {
		if c.Source == d.Winner {
			return strings.TrimSpace(c.Artist)
		}
	}
	return ""
}

func loadEnrichCacheReadOnly(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return
	}
	enrichMu.Lock()
	enrichCache = m
	enrichMu.Unlock()
}
