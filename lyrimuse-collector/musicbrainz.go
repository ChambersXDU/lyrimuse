package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	artistAliasMu    sync.Mutex
	artistAliasCache = map[string]string{}
	artistAliasPath  string
	artistAliasDirty bool
)

func loadArtistAliasCache(path string) {
	artistAliasPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistAliasMu.Lock()
		artistAliasCache = m
		artistAliasMu.Unlock()
		log.Printf("cache: loaded %d artist aliases from %s", len(m), path)
	}
}

func saveArtistAliasCache() {
	artistAliasMu.Lock()
	if !artistAliasDirty || artistAliasPath == "" {
		artistAliasMu.Unlock()
		return
	}

	keep := make(map[string]string, len(artistAliasCache))
	for k, v := range artistAliasCache {
		if v != "" {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	path := artistAliasPath
	if err != nil {
		artistAliasMu.Unlock()
		return
	}
	artistAliasDirty = false
	artistAliasMu.Unlock()

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		artistAliasMu.Lock()
		artistAliasDirty = true
		artistAliasMu.Unlock()
		log.Printf("save artist alias cache: %v", err)
		return
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		artistAliasMu.Lock()
		artistAliasDirty = true
		artistAliasMu.Unlock()
		log.Printf("save artist alias cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		artistAliasMu.Lock()
		artistAliasDirty = true
		artistAliasMu.Unlock()
		log.Printf("save artist alias cache: %v", err)
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		artistAliasMu.Lock()
		artistAliasDirty = true
		artistAliasMu.Unlock()
		log.Printf("save artist alias cache: %v", err)
	}
}

const musicbrainzMinIntervalBetweenCalls = 1100 * time.Millisecond

var (
	musicbrainzRateMu   sync.Mutex
	musicbrainzLastCall time.Time
)

func musicbrainzThrottle(ctx context.Context) error {
	for {
		musicbrainzRateMu.Lock()
		now := time.Now()
		wait := musicbrainzMinIntervalBetweenCalls - now.Sub(musicbrainzLastCall)
		if wait <= 0 {
			musicbrainzLastCall = now
			musicbrainzRateMu.Unlock()
			return nil
		}
		musicbrainzRateMu.Unlock()

		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

var artistCanonicalCacheOnly bool

func canonicalArtistViaMusicBrainz(ctx context.Context, rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}

	artistAliasMu.Lock()
	if v, ok := artistAliasCache[rawArtist]; ok {
		artistAliasMu.Unlock()
		return v
	}
	artistAliasMu.Unlock()
	if artistCanonicalCacheOnly {
		return ""
	}

	resolved := lookupMusicBrainzChineseAlias(ctx, rawArtist)

	artistAliasMu.Lock()
	artistAliasCache[rawArtist] = resolved

	if resolved != "" {
		artistAliasDirty = true
	}
	artistAliasMu.Unlock()
	saveArtistAliasCache()
	return resolved
}

func containsHan(s string) bool {
	return cjkRatio(s) > 0
}

type mbArtistIdentity struct {
	Mbid string `json:"mbid,omitempty"`
	Zh   string `json:"zh,omitempty"`
}

var (
	artistIdentityMu    sync.Mutex
	artistIdentityCache = map[string]mbArtistIdentity{}
	artistIdentityPath  string
	artistIdentityDirty bool
)

func loadArtistIdentityCache(path string) {
	artistIdentityPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]mbArtistIdentity
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistIdentityMu.Lock()
		artistIdentityCache = m
		artistIdentityMu.Unlock()
		log.Printf("cache: loaded %d artist identities from %s", len(m), path)
	}
}

func saveArtistIdentityCache() {
	artistIdentityMu.Lock()
	if !artistIdentityDirty || artistIdentityPath == "" {
		artistIdentityMu.Unlock()
		return
	}
	data, err := json.Marshal(artistIdentityCache)
	artistIdentityDirty = false
	artistIdentityMu.Unlock()
	if err != nil {
		return
	}
	tmp := artistIdentityPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, artistIdentityPath); err != nil {
		log.Printf("save artist identity cache: %v", err)
	}
}

func cachedArtistIdentity(name string) (mbArtistIdentity, bool) {
	artistIdentityMu.Lock()
	defer artistIdentityMu.Unlock()
	id, ok := artistIdentityCache[name]
	return id, ok
}

func resolveArtistIdentityMB(name, knownMbid string) mbArtistIdentity {
	name = strings.TrimSpace(name)
	if name == "" {
		return mbArtistIdentity{}
	}
	ctx := context.Background()
	id := mbArtistIdentity{Mbid: knownMbid}
	if id.Mbid == "" {
		if err := musicbrainzThrottle(ctx); err == nil {
			var search mbSearchResponse
			searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(name) + "&fmt=json&limit=5"
			if err := mbGetJSON(ctx, searchURL, &search); err == nil && len(search.Artists) > 0 &&
				search.Artists[0].Score >= musicbrainzMinScore {
				id.Mbid = search.Artists[0].ID
			}
		}
	}
	if id.Mbid != "" && !containsHan(name) {
		if err := musicbrainzThrottle(ctx); err == nil {
			var withAliases mbArtistWithAliases
			aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(id.Mbid) + "?inc=aliases&fmt=json"
			if err := mbGetJSON(ctx, aliasURL, &withAliases); err == nil {
				id.Zh = pickChineseAlias(withAliases.Aliases, withAliases.Country)
			}
		}
	}
	artistIdentityMu.Lock()
	artistIdentityCache[name] = id
	artistIdentityDirty = true
	artistIdentityMu.Unlock()
	return id
}

type mbSearchResponse struct {
	Artists []struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Score int    `json:"score"`
	} `json:"artists"`
}

type mbAlias struct {
	Name   string `json:"name"`
	Locale string `json:"locale"`

	Type string `json:"type"`
}

type mbArtistWithAliases struct {

	Country string `json:"country"`

	Name    string    `json:"name"`
	Aliases []mbAlias `json:"aliases"`
}

var chineseSpeakingCountries = map[string]bool{
	"CN": true, "TW": true, "HK": true, "MO": true, "SG": true,
}

func pickChineseAlias(aliases []mbAlias, country string) string {
	if !chineseSpeakingCountries[strings.ToUpper(strings.TrimSpace(country))] {
		return ""
	}
	for _, al := range aliases {

		if al.Locale == "ja" {
			continue
		}

		if al.Type == "Legal name" || al.Type == "Search hint" {
			continue
		}
		if containsHan(al.Name) {
			return toSimplified(al.Name)
		}
	}
	return ""
}

const musicbrainzMinScore = 90

func lookupMusicBrainzChineseAlias(ctx context.Context, rawArtist string) string {
	if err := musicbrainzThrottle(ctx); err != nil {
		return ""
	}
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(rawArtist) + "&fmt=json&limit=5"
	if err := mbGetJSON(ctx, searchURL, &search); err != nil || len(search.Artists) == 0 {
		return ""
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return ""
	}

	if err := musicbrainzThrottle(ctx); err != nil {
		return ""
	}
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(ctx, aliasURL, &withAliases); err != nil {
		return ""
	}
	return pickChineseAlias(withAliases.Aliases, withAliases.Country)
}

var (
	mbPrimaryNameMu    sync.Mutex
	mbPrimaryNameCache = map[string][]string{}
	mbPrimaryNamePath  string
	mbPrimaryNameDirty bool
)

func loadMBPrimaryNameCache(path string) {
	mbPrimaryNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string][]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		log.Printf("cache: loaded %d MusicBrainz primary names from %s", len(m), path)
		return
	}
	var legacy map[string]string
	if err := json.Unmarshal(data, &legacy); err == nil && legacy != nil {
		m = make(map[string][]string, len(legacy))
		for k, v := range legacy {
			if v != "" {
				m[k] = []string{v}
			}
		}
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		log.Printf("cache: loaded %d MusicBrainz primary names from %s (legacy format)", len(m), path)
	}
}

func saveMBPrimaryNameCache() {
	mbPrimaryNameMu.Lock()
	if !mbPrimaryNameDirty || mbPrimaryNamePath == "" {
		mbPrimaryNameMu.Unlock()
		return
	}

	keep := make(map[string][]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		if len(v) > 0 {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	mbPrimaryNameDirty = false
	mbPrimaryNameMu.Unlock()
	if err != nil {
		return
	}
	tmp := mbPrimaryNamePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, mbPrimaryNamePath); err != nil {
		log.Printf("save musicbrainz primary name cache: %v", err)
	}
}

func musicBrainzArtistAliases(ctx context.Context, rawArtist string) []string {
	raw := strings.TrimSpace(rawArtist)
	if raw == "" {
		return nil
	}
	mbPrimaryNameMu.Lock()
	if v, ok := mbPrimaryNameCache[raw]; ok {
		mbPrimaryNameMu.Unlock()
		return v
	}
	mbPrimaryNameMu.Unlock()

	resolved, err := lookupMusicBrainzArtistAliases(ctx, raw)
	if err != nil {

		return nil
	}

	mbPrimaryNameMu.Lock()
	mbPrimaryNameCache[raw] = resolved

	if len(resolved) > 0 {
		mbPrimaryNameDirty = true
	}
	mbPrimaryNameMu.Unlock()
	saveMBPrimaryNameCache()
	return resolved
}

func resolvedArtistCJKHint(rawArtist string) string {
	artistAliasMu.Lock()
	if v := artistAliasCache[rawArtist]; v != "" {
		artistAliasMu.Unlock()
		return v
	}
	artistAliasMu.Unlock()

	qqArtistNameMu.Lock()
	if v := qqArtistNameCache[rawArtist]; v != "" {
		qqArtistNameMu.Unlock()
		return v
	}
	qqArtistNameMu.Unlock()

	mbPrimaryNameMu.Lock()
	defer mbPrimaryNameMu.Unlock()
	for _, v := range mbPrimaryNameCache[rawArtist] {
		if containsHan(v) {
			return v
		}
	}
	return ""
}

func resolveGenericArtistCanonicalName(ctx context.Context, rawArtist string) string {
	if v := knownArtistAlias(rawArtist); v != "" {
		return v
	}
	if v := canonicalArtistViaMusicBrainz(ctx, rawArtist); v != "" {
		return v
	}
	return cachedQQArtistCanonicalName(rawArtist)
}

func lookupMusicBrainzArtistAliases(ctx context.Context, raw string) ([]string, error) {
	if err := musicbrainzThrottle(ctx); err != nil {
		return nil, err
	}
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(raw) + "&fmt=json&limit=5"
	if err := mbGetJSON(ctx, searchURL, &search); err != nil {
		return nil, err
	}
	if len(search.Artists) == 0 {
		return nil, nil
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return nil, nil
	}

	if err := musicbrainzThrottle(ctx); err != nil {
		return nil, err
	}
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(ctx, aliasURL, &withAliases); err != nil {
		return nil, err
	}
	primary := withAliases.Name
	if strings.TrimSpace(primary) == "" {
		primary = top.Name
	}
	return mbAliasCandidatesForRetry(primary, withAliases.Aliases, raw), nil
}

func mbAliasCandidatesForRetry(primary string, aliases []mbAlias, raw string) []string {
	primary = strings.TrimSpace(primary)
	raw = strings.TrimSpace(raw)
	if primary == "" || raw == "" {
		return nil
	}
	target := normLoose(raw)
	matched := normLoose(primary) == target
	if !matched {
		for _, al := range aliases {
			if normLoose(al.Name) == target {
				matched = true
				break
			}
		}
	}
	if !matched {
		return nil
	}
	seen := map[string]bool{target: true}
	var out []string
	add := func(name string) {
		name = strings.TrimSpace(name)
		if name == "" {
			return
		}
		k := normLoose(name)
		if seen[k] {
			return
		}
		seen[k] = true
		out = append(out, name)
	}
	add(primary)
	for _, al := range aliases {
		if al.Type != "Artist name" {
			continue
		}
		add(al.Name)
	}
	return out
}

var mbHTTPClient = &http.Client{Timeout: 6 * time.Second}

func mbGetJSON(ctx context.Context, url string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	req.Header.Set("User-Agent", fmt.Sprintf("%s/%s (+https://github.com/Yudaotor/lyrimuse)", clientName, clientVersion))
	resp, err := doHTTPTracked(mbHTTPClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("musicbrainz %s: status %d", url, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}
