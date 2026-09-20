package main

import (
	"context"
	"encoding/json"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const topArtistsCheckInterval = 24 * time.Hour

const topArtistsN = 10

const topArtistsFetchPool = 30

var topArtistsStatePath string

type topArtistsState struct{ path string }

func (s topArtistsState) load() int64 {
	if s.path == "" {
		return 0
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return 0
	}
	var v struct {
		LastAt int64 `json:"last_at"`
	}
	json.Unmarshal(b, &v)
	return v.LastAt
}

func (s topArtistsState) save(at int64) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastAt int64 `json:"last_at"`
	}{at})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

type topArtistEntry struct {
	Name      string `json:"name"`
	PlayCount int    `json:"playCount"`
	Avatar    string `json:"avatar"`
}

func lastfmTopArtists(ctx context.Context, user, apiKey string, limit int) ([]lastfmChartEntry, error) {
	return lastfmTopArtistsPeriod(ctx, user, apiKey, "overall", limit)
}

func lastfmTopArtistsPeriod(ctx context.Context, user, apiKey, period string, limit int) ([]lastfmChartEntry, error) {
	var out struct {
		TopArtists struct {
			Artist []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Mbid      string `json:"mbid"`
			} `json:"artist"`
		} `json:"topartists"`
	}
	params := neturl.Values{
		"method": {"user.getTopArtists"}, "user": {user}, "api_key": {apiKey},
		"period": {period}, "limit": {strconv.Itoa(limit)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.TopArtists.Artist))
	for _, a := range out.TopArtists.Artist {
		pc, _ := strconv.Atoi(a.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: a.Name, PlayCount: pc, Mbid: a.Mbid})
	}
	return entries, nil
}

func artistMergeNameKey(name string) string {
	first := firstCreditedArtist(name)
	if alias := resolveGenericArtistCanonicalName(context.Background(), first); alias != "" {
		first = alias
	}
	return strings.ToLower(toSimplified(first))
}

func artistMergeDisplayName(name string) string {
	if alias := resolveGenericArtistCanonicalName(context.Background(), name); alias != "" {
		return alias
	}
	return name
}

type artistIdentityFn func(name, knownMbid string) mbArtistIdentity

func cacheOnlyArtistIdentity(name, _ string) mbArtistIdentity {
	id, _ := cachedArtistIdentity(strings.TrimSpace(name))
	return id
}

func budgetedArtistIdentity(budget int) artistIdentityFn {
	var mu sync.Mutex
	remaining := budget
	return func(name, knownMbid string) mbArtistIdentity {
		name = strings.TrimSpace(name)
		if name == "" {
			return mbArtistIdentity{}
		}
		if id, ok := cachedArtistIdentity(name); ok {
			return id
		}
		mu.Lock()
		if remaining <= 0 {
			mu.Unlock()
			return mbArtistIdentity{}
		}
		remaining--
		mu.Unlock()
		return resolveArtistIdentityMB(name, knownMbid)
	}
}

func warmArtistIdentityCache(ctx context.Context, entries []lastfmChartEntry, budget int) {
	if ctx == nil {
		ctx = context.Background()
	}
	resolve := budgetedArtistIdentity(budget)
	for _, e := range entries {
		select {
		case <-ctx.Done():
			return
		default:
		}
		first := firstCreditedArtist(e.Name)
		mbid := ""
		if strings.EqualFold(strings.TrimSpace(first), strings.TrimSpace(e.Name)) {

			mbid = e.Mbid
		}
		resolve(first, mbid)
	}
	saveArtistIdentityCache()
}

func mergeAliasedArtists(entries []lastfmChartEntry) []lastfmChartEntry {
	return mergeAliasedArtistsResolved(entries, cacheOnlyArtistIdentity)
}

func mergeAliasedArtistsResolved(entries []lastfmChartEntry, resolve artistIdentityFn) []lastfmChartEntry {
	n := len(entries)
	nameKeys := make([]string, n)
	ids := make([]mbArtistIdentity, n)
	for i, e := range entries {
		nameKeys[i] = artistMergeNameKey(e.Name)
		first := firstCreditedArtist(e.Name)
		mbid := ""
		if strings.EqualFold(strings.TrimSpace(first), strings.TrimSpace(e.Name)) {
			mbid = e.Mbid
		}
		ids[i] = resolve(first, mbid)
	}

	parent := make([]int, n)
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(x int) int {
		for parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	union := func(a, b int) {
		if ra, rb := find(a), find(b); ra != rb {
			parent[ra] = rb
		}
	}

	groups := map[string][]int{}
	addKey := func(k string, i int) {
		if k != "" {
			groups[k] = append(groups[k], i)
		}
	}
	for i, e := range entries {
		if nameKeys[i] != "" {
			addKey("n:"+nameKeys[i], i)
		}
		mbid := e.Mbid
		if mbid == "" {
			mbid = ids[i].Mbid
		}
		if mbid != "" {
			addKey("m:"+mbid, i)
		}
		if ids[i].Zh != "" {
			addKey("n:"+strings.ToLower(toSimplified(ids[i].Zh)), i)
		}
	}
	for _, idxs := range groups {
		for k := 1; k < len(idxs); k++ {
			union(idxs[0], idxs[k])
		}
	}

	type bucket struct {
		name      string
		nameParts int
		hanName   string
		zh        string
		playCount int
	}
	buckets := make(map[int]*bucket, n)
	order := make([]int, 0, n)
	for i, e := range entries {
		root := find(i)
		display := artistMergeDisplayName(e.Name)
		parts := len(artistCreditParts(e.Name))
		b, ok := buckets[root]
		if !ok {
			b = &bucket{name: display, nameParts: parts}
			buckets[root] = b
			order = append(order, root)
		} else if parts < b.nameParts {
			b.name, b.nameParts = display, parts
		}

		if parts == 1 && containsHan(display) && b.hanName == "" {
			b.hanName = display
		}
		if b.zh == "" && ids[i].Zh != "" {
			b.zh = ids[i].Zh
		}
		b.playCount += e.PlayCount
	}

	out := make([]lastfmChartEntry, 0, len(order))
	for _, root := range order {
		b := buckets[root]
		name := b.name

		if b.hanName != "" {
			name = b.hanName
		} else if b.zh != "" {
			name = b.zh
		}
		out = append(out, lastfmChartEntry{Name: name, PlayCount: b.playCount})
	}

	sort.SliceStable(out, func(i, j int) bool { return out[i].PlayCount > out[j].PlayCount })
	return out
}

func resolveArtistAvatar(ctx context.Context, name string) (string, bool) {
	qqPic, qqDef := qqSingerAvatar(ctx, name)
	if qqPic != "" {
		return qqPic, true
	}
	dzPic, dzDef := deezerArtistAvatar(ctx, name)
	if dzPic != "" {
		return dzPic, true
	}

	return "", qqDef && dzDef
}

func deezerArtistAvatar(ctx context.Context, name string) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u := "https://api.deezer.com/search/artist?limit=1&q=" + neturl.QueryEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var out struct {
		Data []struct {
			PictureMedium string `json:"picture_medium"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", false
	}
	if len(out.Data) == 0 {
		return "", true
	}
	return out.Data[0].PictureMedium, true
}

func (p *poller) topArtistsDigest(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.lastfmBridgeAPIKey() == "" || p.cfg.StateRelayURL == "" {
		return
	}
	if !p.topArtistsLastCheckedAt.IsZero() && now.Sub(p.topArtistsLastCheckedAt) < topArtistsCheckInterval {
		return
	}
	p.topArtistsLastCheckedAt = now
	if last := p.topArtistsState.load(); last > 0 && now.Sub(time.Unix(last, 0)) < topArtistsCheckInterval {
		return
	}

	entries, err := lastfmTopArtists(p.ctx, p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey(), topArtistsFetchPool)
	if err != nil || len(entries) == 0 {
		return
	}

	go warmArtistIdentityCache(p.ctx, entries, topArtistsFetchPool)
	merged := mergeAliasedArtists(entries)
	if len(merged) > topArtistsN {
		merged = merged[:topArtistsN]
	}

	artists := make([]topArtistEntry, len(merged))
	{
		var wg sync.WaitGroup
		sem := make(chan struct{}, 4)
		for i, e := range merged {
			wg.Add(1)
			go func(i int, name string, playCount int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				avatar, _ := resolveArtistAvatar(p.ctx, name)
				artists[i] = topArtistEntry{
					Name: name, PlayCount: playCount,
					Avatar: avatar,
				}
			}(i, e.Name, e.PlayCount)
		}
		wg.Wait()
	}
	payload := map[string]any{"artists": artists, "updatedAt": now.Unix()}
	if err := postRelay(p.ctx, p.cfg, "/top-artists", payload); err != nil {
		return
	}
	p.topArtistsState.save(now.Unix())
}
