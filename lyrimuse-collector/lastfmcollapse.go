package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (

	lastfmCatalogListenersMin = 500

	lastfmCollapseDeferRecheck = 90 * 24 * time.Hour

	lastfmCollapseBudget = 6 * time.Second

	lastfmCollapseProbeTimeout = 4 * time.Second
)

var lastfmCollapsePath string

type collapseVerdict string

const (

	verdictKeep collapseVerdict = "keep"

	verdictCollapse collapseVerdict = "collapse"

	verdictDefer collapseVerdict = "defer"
)

type lastfmCatalogProbe struct {

	Found      bool   `json:"found"`
	MBID       string `json:"mbid,omitempty"`
	Listeners  int    `json:"listeners"`
	DurationMS int    `json:"duration_ms"`
}

func (p lastfmCatalogProbe) catalogued() bool {
	return p.Found && (p.MBID != "" || p.Listeners >= lastfmCatalogListenersMin || p.DurationMS > 0)
}

type lastfmCollapseDecision struct {
	Verdict collapseVerdict `json:"verdict"`

	Artist string `json:"artist"`
	TS     int64  `json:"ts"`

	Joint   *lastfmCatalogProbe `json:"joint,omitempty"`
	Primary *lastfmCatalogProbe `json:"primary,omitempty"`
}

type lastfmArtistCollapser struct {
	apiKey  string
	baseURL string
	hc      *http.Client

	mu    sync.Mutex
	cache map[string]lastfmCollapseDecision
}

func newLastfmArtistCollapser(apiKey string) *lastfmArtistCollapser {
	if apiKey == "" {
		return nil
	}
	c := &lastfmArtistCollapser{
		apiKey: apiKey,
		hc:     &http.Client{Timeout: lastfmCollapseProbeTimeout},
		cache:  map[string]lastfmCollapseDecision{},
	}
	c.load()
	return c
}

func (c *lastfmArtistCollapser) resolve(ctx context.Context, artist, track string) string {
	if c == nil {
		return artist
	}
	trimmed := strings.TrimSpace(artist)
	if trimmed == "" || strings.TrimSpace(track) == "" {
		return artist
	}

	primary := firstCreditedArtist(trimmed)
	if primary == "" || primary == trimmed {
		return artist
	}

	key := trimmed + "\n" + track
	if d, ok := c.lookup(key, time.Now()); ok {
		return d.Artist
	}

	ctx, cancel := context.WithTimeout(ctx, lastfmCollapseBudget)
	defer cancel()
	joint, err := c.probe(ctx, trimmed, track)
	if err != nil {

		log.Printf("lastfm smart artist: lookup %q / %q failed: %v (keeping as-is, not cached)", trimmed, track, err)
		return artist
	}
	if joint.catalogued() {
		c.store(key, lastfmCollapseDecision{Verdict: verdictKeep, Artist: trimmed, Joint: &joint})
		log.Printf("lastfm smart artist: keep %q / %q (joint credit is catalogued: %s)", trimmed, track, joint.summary())
		return trimmed
	}
	target, err := c.probe(ctx, primary, track)
	if err != nil {
		log.Printf("lastfm smart artist: target lookup %q / %q failed: %v (keeping as-is, not cached)", primary, track, err)
		return artist
	}
	if target.catalogued() {
		c.store(key, lastfmCollapseDecision{Verdict: verdictCollapse, Artist: primary, Joint: &joint, Primary: &target})
		log.Printf("lastfm smart artist: %q -> %q for %q (joint credit not catalogued: %s; target catalogued: %s)",
			trimmed, primary, track, joint.summary(), target.summary())
		return primary
	}
	c.store(key, lastfmCollapseDecision{Verdict: verdictDefer, Artist: trimmed, Joint: &joint, Primary: &target})
	log.Printf("lastfm smart artist: defer %q / %q (neither joint nor %q is catalogued; keeping as-is, recheck after %s)",
		trimmed, track, primary, lastfmCollapseDeferRecheck)
	return trimmed
}

func (p lastfmCatalogProbe) summary() string {
	if !p.Found {
		return "not found"
	}
	return fmt.Sprintf("mbid=%q listeners=%d duration_ms=%d", p.MBID, p.Listeners, p.DurationMS)
}

func (c *lastfmArtistCollapser) probe(ctx context.Context, artist, track string) (lastfmCatalogProbe, error) {
	q := neturl.Values{}
	q.Set("method", "track.getInfo")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("artist", artist)
	q.Set("track", track)

	q.Set("autocorrect", "1")

	base := c.baseURL
	if base == "" {
		base = "https://ws.audioscrobbler.com/2.0/"
	}
	ctx, cancel := context.WithTimeout(ctx, lastfmCollapseProbeTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+lastfmGetQuery(q), nil)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("get track info: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		Track struct {
			MBID      string `json:"mbid"`
			Listeners string `json:"listeners"`
			Duration  string `json:"duration"`
		} `json:"track"`
		Error   int    `json:"error"`
		Message string `json:"message"`
	}

	decodeErr := json.NewDecoder(resp.Body).Decode(&body)
	if body.Error == 6 && strings.Contains(strings.ToLower(body.Message), "not found") {
		return lastfmCatalogProbe{Found: false}, nil
	}
	if resp.StatusCode != http.StatusOK {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo status %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("decode track.getInfo: %w", decodeErr)
	}
	if body.Error != 0 {

		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo error %d: %s", body.Error, body.Message)
	}
	p := lastfmCatalogProbe{Found: true, MBID: body.Track.MBID}

	if p.Listeners, err = atoiOrZero(body.Track.Listeners); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo listeners %q: %w", body.Track.Listeners, err)
	}
	if p.DurationMS, err = atoiOrZero(body.Track.Duration); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo duration %q: %w", body.Track.Duration, err)
	}
	return p, nil
}

func atoiOrZero(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	return strconv.Atoi(s)
}

func (c *lastfmArtistCollapser) lookup(key string, now time.Time) (lastfmCollapseDecision, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.cache[key]
	if !ok {
		return d, false
	}
	switch d.Verdict {
	case verdictKeep, verdictCollapse:
		return d, true
	case verdictDefer:
		return d, now.Sub(time.Unix(d.TS, 0)) <= lastfmCollapseDeferRecheck
	default:
		return d, false
	}
}

func (c *lastfmArtistCollapser) store(key string, d lastfmCollapseDecision) {
	d.TS = time.Now().Unix()
	c.mu.Lock()
	c.cache[key] = d
	snapshot := make(map[string]lastfmCollapseDecision, len(c.cache))
	for k, v := range c.cache {
		snapshot[k] = v
	}
	c.mu.Unlock()
	c.save(snapshot)
}

func (c *lastfmArtistCollapser) load() {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := os.ReadFile(lastfmCollapsePath)
	if err != nil {
		return
	}
	var m map[string]lastfmCollapseDecision
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("lastfm smart artist: cache unreadable, starting empty: %v", err)
		return
	}

	for k, d := range m {
		switch d.Verdict {
		case verdictKeep, verdictCollapse, verdictDefer:
		default:
			delete(m, k)
		}
	}
	c.mu.Lock()
	c.cache = m
	c.mu.Unlock()
}

func (c *lastfmArtistCollapser) save(snapshot map[string]lastfmCollapseDecision) {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		log.Printf("lastfm smart artist: marshal cache: %v", err)
		return
	}

	tmp := fmt.Sprintf("%s.tmp.%d", lastfmCollapsePath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("lastfm smart artist: write cache: %v", err)
		return
	}
	if err := os.Rename(tmp, lastfmCollapsePath); err != nil {
		log.Printf("lastfm smart artist: rename cache: %v", err)
		_ = os.Remove(tmp)
	}
}
