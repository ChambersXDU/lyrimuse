package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---- Album Hint Backfill ----
//
// When a player does not report an album name (e.g. YouTube Music video/MV tracks where
// MediaSession reports an empty album), this module queries the Apple Catalog (iTunes Search API)
// using artist + title + duration to resolve the track's original album.
//
// Invariant: The hint album is used strictly for presentation and external uploads
// (snapshot.AlbumHint -> relay web page, Last.fm scrobble album, ListenBrainz release_name,
// and local listen log). It MUST NEVER modify the enrich cache key, because the Swift frontend
// queries lyrics using the player-reported `artist|title|album`. If modified here, the keys
// would mismatch and lyric lookups would fail. Ad break detection (isAdBreak), album prefetch,
// and session keys also continue using the raw Album.
//
// Two-stage architecture:
//   - Candidate fetching (fetchAppleAlbumHintCandidates, asynchronous background query):
//     Queries "Artist Title" and bare "Title" across CN and US storefronts. Retains candidates
//     where normalized title matches exactly, duration is within appleTitleSearchDurationTolerance
//     (max(4s, 3%)), and album is non-empty. Performs a single batch collection lookup to obtain
//     collection-level release dates (since track releaseDate is the original track release date).
//     If primary query yields zero candidates, attempts albumHintTitleSplit ("Artist - Title" format).
//   - Candidate picking (pickAppleAlbumHint, pure function executed per tick from memory):
//     Evaluates candidate artist across two tiers: Tier 0 (exact match or credit subset, e.g.
//     "Prince" vs "Prince & The Revolution") and Tier 1 (lyric-resolved artists from enrich
//     or winning lyric candidate). Candidates failing both tiers are rejected to avoid mismatched
//     instrumental/piano covers. Within a tier, candidates are ranked: non-compilation >
//     non-single/EP > non-deluxe/remaster > earliest album release date > Apple search order.
//
// Poller lifecycle discipline: The main poll loop only reads the in-memory cache and triggers
// background fetching on a cache miss to prevent network latency from blocking the polling tick.
const appleAlbumHintMaxMisses = 2

// albumHintCandidate 是一条"曲名 + 时长对得上"的 Apple 目录候选,落盘后每拍重挑。
type albumHintCandidate struct {
	Artist string `json:"artist"`
	// TitleArtist:这条候选的署名旁证来自**曲名破折号前段**(搬运频道形态,见 albumHintTitleSplit),取候选时已核过
	// Apple 署名与它 0 档相符;挑的时候凭它当 0 档,不再要求跟播放器那格署名(频道名)相等。主查询有候选时恒为空。
	TitleArtist string `json:"title_artist,omitempty"`
	// CollectionArtist:专辑级署名,iTunes 只在它跟曲目署名不同时才给(群星合辑 / 别人专辑里客串)。
	CollectionArtist string `json:"collection_artist,omitempty"`
	Album            string `json:"album"`
	CollectionID     int64  `json:"collection_id,omitempty"`
	// TrackRelease:iTunes Search 给的 releaseDate —— 是**歌**的首发日期,只作兜底排序。
	TrackRelease string `json:"track_release,omitempty"`
	// AlbumRelease:lookup 到的**专辑**发行日期(ISO 8601,字符串序即时间序)。
	AlbumRelease string `json:"album_release,omitempty"`
	// Order:Apple 返回顺序,最后的平手项。
	Order int `json:"order"`
}

var (
	appleAlbumHintMu       sync.Mutex
	appleAlbumHintCache    = map[string][]albumHintCandidate{} // key → 候选,只存非空的
	appleAlbumHintPath     string                              // 空 = 只用内存(单测 / 一次性子命令)
	appleAlbumHintDirty    bool
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintWaiters  = map[string]chan struct{}{}
	appleAlbumHintMisses   = map[string]int{}
	appleAlbumHintLogged   = map[string]string{} // key → 已打过日志的挑选结果,同一首只记一行

	albumHintLookupHTTPClient = &http.Client{Timeout: 6 * time.Second}
)

// appleAlbumHintKey:署名|曲名|整秒时长,刻意不 normLoose —— 缓存里存的是原始标签对应的候选。
func appleAlbumHintKey(artist, title string, durationSecs float64) string {
	return strings.TrimSpace(artist) + "|" + strings.TrimSpace(title) + "|" + fmt.Sprintf("%.0f", durationSecs)
}

// appleAlbumHintEligible:值不值得为这条播放去问。署名 / 曲名缺一不问;时长缺或短于
// appleTitleSearchMinDurationSecs 不问(几十秒的 Intro / Outro 最容易撞同名,理由见 applecatalog.go)。
func appleAlbumHintEligible(artist, title string, durationSecs float64) bool {
	return strings.TrimSpace(artist) != "" && strings.TrimSpace(title) != "" &&
		durationSecs >= appleTitleSearchMinDurationSecs
}

// loadAppleAlbumHintCache/saveAppleAlbumHintCache:跟 loadAppleCatalogCache 同一套(整份 map + 临时文件原子改名)。
func loadAppleAlbumHintCache(path string) {
	appleAlbumHintMu.Lock()
	appleAlbumHintPath = path
	appleAlbumHintMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string][]albumHintCandidate
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		appleAlbumHintMu.Lock()
		appleAlbumHintCache = m
		appleAlbumHintMu.Unlock()
		log.Printf("cache: loaded %d Apple album-hint candidate sets from %s", len(m), path)
	}
}

func saveAppleAlbumHintCache() {
	appleAlbumHintMu.Lock()
	if !appleAlbumHintDirty || appleAlbumHintPath == "" {
		appleAlbumHintMu.Unlock()
		return
	}
	data, err := json.Marshal(appleAlbumHintCache)
	path := appleAlbumHintPath
	if err != nil {
		appleAlbumHintMu.Unlock()
		return
	}
	appleAlbumHintDirty = false
	appleAlbumHintMu.Unlock()

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		appleAlbumHintMu.Lock()
		appleAlbumHintDirty = true
		appleAlbumHintMu.Unlock()
		log.Printf("save apple album hint cache: %v", err)
	}
}

// appleAlbumHint 给 poll 主循环用:候选已缓存就当场挑一个回来(可能为空 —— 旁证还没到),没查过就后台补一次、
// 本轮先按现状走。resolvedArtists 是歌词链路核实过的署名(lyricResolvedArtists),挑 1 档候选时用。
func appleAlbumHint(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)
	appleAlbumHintMu.Lock()
	if cands, ok := appleAlbumHintCache[key]; ok {
		appleAlbumHintMu.Unlock()
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}
	if appleAlbumHintInflight[key] || appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
		appleAlbumHintMu.Unlock()
		return ""
	}
	appleAlbumHintInflight[key] = true
	waitCh := make(chan struct{})
	appleAlbumHintWaiters[key] = waitCh
	appleAlbumHintMu.Unlock()
	go func() {
		cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
		storeAppleAlbumHintResult(key, cands, concluded)
	}()
	return ""
}

// appleAlbumHintSyncWait defines the maximum wait duration for background resolution
// when an Apple Catalog hint query initiated by the main poll loop is already inflight.
const appleAlbumHintSyncWait = 8 * time.Second

// appleAlbumHintSync resolves an album hint synchronously for background processing pipelines
// (resolveTrackEnrichment, backfillPeripheralFields, recheck-cover CLI).
// If candidates are not cached, it queries immediately and picks from the result.
// If another query is already inflight, it waits on the shared notification channel.
//
// Blocking call that acquires appleAlbumHintMu; must not be called from the main poll loop
// or while holding enrichMu.
func appleAlbumHintSync(ctx context.Context, artist, title string, durationSecs float64, resolvedArtists []string) string {
	if !appleAlbumHintEligible(artist, title, durationSecs) {
		return ""
	}
	key := appleAlbumHintKey(artist, title, durationSecs)

	appleAlbumHintMu.Lock()
	if cands, ok := appleAlbumHintCache[key]; ok {
		appleAlbumHintMu.Unlock()
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}

	if !appleAlbumHintInflight[key] {
		if appleAlbumHintMisses[key] >= appleAlbumHintMaxMisses {
			appleAlbumHintMu.Unlock()
			return ""
		}
		appleAlbumHintInflight[key] = true
		waitCh := make(chan struct{})
		appleAlbumHintWaiters[key] = waitCh
		appleAlbumHintMu.Unlock()

		cands, concluded := fetchAppleAlbumHintCandidatesTracked(ctx, artist, title, durationSecs)
		storeAppleAlbumHintResult(key, cands, concluded)
		if len(cands) == 0 {
			return ""
		}
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	}

	// Already in-flight! Get or create wait channel to synchronize without busy-polling.
	waitCh, ok := appleAlbumHintWaiters[key]
	if !ok {
		waitCh = make(chan struct{})
		appleAlbumHintWaiters[key] = waitCh
	}
	appleAlbumHintMu.Unlock()

	// Wait cleanly on the channel for completion, context cancellation, or sync timeout.
	timer := time.NewTimer(appleAlbumHintSyncWait)
	defer timer.Stop()

	select {
	case <-waitCh:
		appleAlbumHintMu.Lock()
		cands := appleAlbumHintCache[key]
		appleAlbumHintMu.Unlock()
		if len(cands) == 0 {
			return ""
		}
		return pickAppleAlbumHintLogged(key, cands, artist, title, durationSecs, resolvedArtists)
	case <-ctx.Done():
		return ""
	case <-timer.C:
		return ""
	}
}

// storeAppleAlbumHintResult 把一次候选查询的结果记进缓存,并清掉在途标记并唤醒所有等待者。
func storeAppleAlbumHintResult(key string, cands []albumHintCandidate, concluded bool) {
	appleAlbumHintMu.Lock()
	delete(appleAlbumHintInflight, key)
	if ch, ok := appleAlbumHintWaiters[key]; ok {
		delete(appleAlbumHintWaiters, key)
		close(ch)
	}
	if len(cands) == 0 {
		if concluded {
			appleAlbumHintMisses[key]++
		}
	} else {
		appleAlbumHintCache[key] = cands
		appleAlbumHintDirty = true
	}
	appleAlbumHintMu.Unlock()
	if len(cands) > 0 {
		saveAppleAlbumHintCache()
	}
}

// pickAppleAlbumHintLogged:挑一个并把结果记一行日志(同一首同一结果只记一次,旁证晚到换了结果再记一次)。
// cands 是缓存里那份切片,存进去之后没人原地改,不持锁读是安全的。
func pickAppleAlbumHintLogged(key string, cands []albumHintCandidate, artist, title string, durationSecs float64, resolvedArtists []string) string {
	album := pickAppleAlbumHint(cands, artist, resolvedArtists)
	if album == "" {
		return ""
	}
	appleAlbumHintMu.Lock()
	logged := appleAlbumHintLogged[key] == album
	if !logged {
		appleAlbumHintLogged[key] = album
	}
	appleAlbumHintMu.Unlock()
	if !logged {
		log.Printf("album hint: %q - %q (%.0fs) -> %q (apple catalog, %d candidates)", artist, title, durationSecs, album, len(cands))
	}
	return album
}

// coverAlbumForTrack determines the album name used for cover art verification and swapping.
// Returns the player-reported album if present; otherwise falls back to the Apple Catalog hint
// from cache (without blocking on network I/O). The hint album is used only during candidate
// evaluation (e.g. Apple matching score, NetEase vs Apple album guard, coverSwapAllowed) and is
// never persisted as cover_album, preserving cover_album as an authoritative verified-match record.
//
// Acquires enrichMu internally via lyricResolvedArtists; must not be called while holding enrichMu.
func coverAlbumForTrack(ctx context.Context, artist, title, album string, durationSecs float64) string {
	if album != "" {
		return album
	}
	return appleAlbumHint(ctx, artist, title, durationSecs, lyricResolvedArtists(artist, title, album))
}

// coverAlbumCorroboration gathers artist corroboration from all available sources: existing
// enrich cache (lyricResolvedArtists), current MusicBrainz canonical artist, and current winning
// lyric candidate artist.
func coverAlbumCorroboration(artist, title, album, canonical string, picked *scoredLyricCandidateResult) []string {
	out := lyricResolvedArtists(artist, title, album)
	if strings.TrimSpace(canonical) != "" {
		out = append(out, canonical)
	}
	if picked != nil && strings.TrimSpace(picked.Artist) != "" {
		out = append(out, picked.Artist)
	}
	return out
}

// coverNeedsHintCheck evaluates whether cover art should be re-selected using the hinted album.
// Triggers when the player reported no album, an Apple Catalog album hint was resolved, and the
// current cover belongs to an entirely different album (albumScore == 0). Checks NetEase and Apple
// sources, where cover_album is reported directly by the provider.
func coverNeedsHintCheck(e enrichEntry, album, hint string) bool {
	if album != "" || hint == "" || e.CoverURL == "" || e.CoverAlbum == "" {
		return false
	}
	if e.CoverSource != "netease" && e.CoverSource != "apple" {
		return false
	}
	return albumScore(e.CoverAlbum, hint) == 0
}

// fetchAppleAlbumHintCandidates 打 iTunes Search(两个查询 × 两个商店,合并去重),再用一次 lookup 补专辑级发行日期。
func fetchAppleAlbumHintCandidates(ctx context.Context, artist, title string, durationSecs float64) []albumHintCandidate {
	var results []itunesResult
	for _, q := range []string{strings.TrimSpace(artist + " " + title), title} {
		for _, country := range []string{"CN", "US"} {
			results = append(results, itunesSearch(ctx, neturl.QueryEscape(q), country)...)
		}
	}
	cands := albumHintCandidatesFromResults(results, title, durationSecs)
	if len(cands) == 0 {
		// 搬运频道形态兜底:署名位是频道名、歌手写在曲名破折号前面,见 albumHintTitleSplit。只发「前段 后段」一个查询。
		if titleArtist, song, ok := albumHintTitleSplit(title); ok {
			var alt []itunesResult
			q := neturl.QueryEscape(titleArtist + " " + song)
			for _, country := range []string{"CN", "US"} {
				alt = append(alt, itunesSearch(ctx, q, country)...)
			}
			cands = albumHintCandidatesFromTitleSplit(alt, titleArtist, song, durationSecs)
		}
	}
	if len(cands) == 0 {
		return nil
	}
	var ids []int64
	seen := map[int64]bool{}
	for _, c := range cands {
		if c.CollectionID != 0 && !seen[c.CollectionID] {
			seen[c.CollectionID] = true
			ids = append(ids, c.CollectionID)
		}
	}
	releases := itunesLookupCollectionReleaseDates(ctx, ids, "US")
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	return cands
}

// fetchAppleAlbumHintCandidatesTracked wraps fetchAppleAlbumHintCandidates with network round
// observation (beginNetworkRound) to determine whether an empty result constitutes a definitive miss.
// Network failures (DNS errors, timeouts, context cancellation) are not counted as misses against
// appleAlbumHintMaxMisses, preventing transient network glitches from permanently disabling album hints.
//
// When concluded is false, callers clear the inflight flag without recording a miss.
func fetchAppleAlbumHintCandidatesTracked(ctx context.Context, artist, title string, durationSecs float64) (cands []albumHintCandidate, concluded bool) {
	end := beginNetworkRound()
	cands = fetchAppleAlbumHintCandidates(ctx, artist, title, durationSecs)
	attempts, failures := end()
	return cands, appleAlbumHintQueryConcluded(len(cands), attempts, failures)
}

// appleAlbumHintQueryConcluded determines whether a candidate query result is definitive.
// Any non-empty candidate list is concluded. An empty result is concluded only if at least
// one network request reached the server and received a response, using lyricsRoundConfirmsNoResult.
func appleAlbumHintQueryConcluded(n int, attempts, failures int32) bool {
	return n > 0 || lyricsRoundConfirmsNoResult(attempts, failures)
}

// albumHintCandidatesFromResults filters candidate results by title equality, duration tolerance,
// and non-empty metadata, deduplicating across CN and US storefronts by artist|album.
func albumHintCandidatesFromResults(results []itunesResult, title string, durationSecs float64) []albumHintCandidate {
	want := normLoose(title)
	if want == "" || durationSecs < appleTitleSearchMinDurationSecs {
		return nil
	}
	tolerance := appleTitleSearchDurationTolerance(durationSecs)
	var out []albumHintCandidate
	seen := map[string]bool{}
	for _, r := range results {
		if normLoose(r.TrackName) != want {
			continue
		}
		if r.TrackTimeMillis <= 0 || math.Abs(r.TrackTimeMillis/1000-durationSecs) > tolerance {
			continue
		}
		album, who := cleanMediaTag(r.CollectionName), cleanMediaTag(r.ArtistName)
		if album == "" || who == "" {
			continue
		}
		dk := normLoose(who) + "|" + normLoose(album)
		if seen[dk] {
			continue
		}
		seen[dk] = true
		out = append(out, albumHintCandidate{
			Artist: who, CollectionArtist: cleanMediaTag(r.CollectionArtistName), Album: album,
			CollectionID: r.CollectionID, TrackRelease: r.ReleaseDate, Order: len(out),
		})
	}
	return out
}

// albumHintTitleSplit extracts artist and song title from tracks where the channel/uploader
// name is reported as the artist and the song title is formatted as "Artist - Title".
// Strips non-version bracket suffixes (e.g. "(Official Video)", "[HD]") via normEnrichTitle,
// then splits on the first hyphen delimiter (" - ", " – ", " — ").
// Only invoked when primary catalog queries yield zero candidates.
func albumHintTitleSplit(title string) (artist, song string, ok bool) {
	clean := normEnrichTitle(title)
	best, sepLen := -1, 0
	for _, sep := range []string{" - ", " – ", " — "} {
		if i := strings.Index(clean, sep); i >= 0 && (best < 0 || i < best) {
			best, sepLen = i, len(sep)
		}
	}
	if best < 0 {
		return "", "", false
	}
	artist, song = strings.TrimSpace(clean[:best]), strings.TrimSpace(clean[best+sepLen:])
	if normLoose(artist) == "" || normLoose(song) == "" {
		return "", "", false
	}
	return artist, song, true
}

// albumHintCandidatesFromTitleSplit:拆出来的身份取候选 —— 在 albumHintCandidatesFromResults 的三道门(曲名归一相等 /
// 时长容差 / 专辑署名非空)之上再加一道:Apple 署名必须与曲名前段 0 档相符(归一相等或 credit 子集),并把前段记进
// TitleArtist 落盘,挑的时候凭它当 0 档。播放器那格署名(频道名)在这条路上不参与比对。
func albumHintCandidatesFromTitleSplit(results []itunesResult, titleArtist, song string, durationSecs float64) []albumHintCandidate {
	var out []albumHintCandidate
	for _, c := range albumHintCandidatesFromResults(results, song, durationSecs) {
		if albumHintArtistTier(titleArtist, c.Artist, nil) != 0 {
			continue
		}
		c.TitleArtist = titleArtist
		out = append(out, c)
	}
	return out
}

// itunesLookupCollectionReleaseDates:一次 lookup 拿一批专辑的发行日期(id 逗号串起来,iTunes 允许最多 200 个)。
// 失败返回 nil,调用方退回曲目级日期排序。
func itunesLookupCollectionReleaseDates(ctx context.Context, ids []int64, country string) map[int64]string {
	if len(ids) == 0 {
		return nil
	}
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		parts = append(parts, fmt.Sprint(id))
	}
	u := "https://itunes.apple.com/lookup?country=" + country + "&id=" + strings.Join(parts, ",")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(albumHintLookupHTTPClient, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType  string `json:"wrapperType"`
			CollectionID int64  `json:"collectionId"`
			ReleaseDate  string `json:"releaseDate"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	m := map[int64]string{}
	for _, r := range out.Results {
		if r.WrapperType == "collection" && r.CollectionID != 0 && r.ReleaseDate != "" {
			m[r.CollectionID] = r.ReleaseDate
		}
	}
	return m
}

// pickAppleAlbumHint 从候选里挑一张,纯函数。判据见头注。
func pickAppleAlbumHint(cands []albumHintCandidate, artist string, resolvedArtists []string) string {
	resolved := map[string]bool{}
	for _, a := range resolvedArtists {
		if n := normLoose(a); n != "" {
			resolved[n] = true
		}
	}
	type scored struct {
		c       albumHintCandidate
		rank    int
		release string
	}
	var accepted []scored
	for _, c := range cands {
		tier := albumHintArtistTier(artist, c.Artist, resolved)
		if tier < 0 && c.TitleArtist != "" && albumHintArtistTier(c.TitleArtist, c.Artist, nil) == 0 {
			tier = 0 // 署名旁证来自曲名破折号前段(搬运频道形态),取候选时已核过,见 albumHintCandidatesFromTitleSplit
		}
		if tier < 0 {
			continue
		}
		rank := tier * 10
		if c.CollectionArtist != "" && normLoose(c.CollectionArtist) != normLoose(c.Artist) {
			rank += 4 // 专辑署名跟曲目署名不是一个人:群星合辑 / 别人的专辑里客串
		}
		if albumHintIsSingleOrEP(c.Album) {
			rank += 2
		}
		if albumHintHasEditionQualifier(c.Album) {
			rank++
		}
		release := c.AlbumRelease
		if release == "" {
			release = c.TrackRelease
		}
		accepted = append(accepted, scored{c: c, rank: rank, release: release})
	}
	if len(accepted) == 0 {
		return ""
	}
	sort.SliceStable(accepted, func(a, b int) bool {
		if accepted[a].rank != accepted[b].rank {
			return accepted[a].rank < accepted[b].rank
		}
		ra, rb := accepted[a].release, accepted[b].release
		if ra != rb {
			if ra == "" {
				return false
			}
			if rb == "" {
				return true
			}
			return ra < rb
		}
		return accepted[a].c.Order < accepted[b].c.Order
	})
	return accepted[0].c.Album
}

// albumHintArtistTier:0 = 署名本身对得上(归一相等 / credit 子集,含繁简折叠);1 = 歌词链路核实过的署名
// (跨文字系统只认这条旁证);-1 = 不采。
func albumHintArtistTier(local, candidate string, resolved map[string]bool) int {
	l, c := normLoose(local), normLoose(candidate)
	if l == "" || c == "" {
		return -1
	}
	if l == c {
		return 0
	}
	lp, cp := artistCreditParts(local), artistCreditParts(candidate)
	if len(lp) > 0 && len(cp) > 0 && (creditPartsSubset(lp, cp) || creditPartsSubset(cp, lp)) {
		return 0
	}
	if resolved[c] {
		return 1
	}
	return -1
}

// creditPartsSubset:a 里的每个署名都在 b 里(按 normLoose 比)。
func creditPartsSubset(a, b []string) bool {
	set := map[string]bool{}
	for _, p := range b {
		set[normLoose(p)] = true
	}
	for _, p := range a {
		if !set[normLoose(p)] {
			return false
		}
	}
	return true
}

// albumHintIsSingleOrEP:Apple 给单曲 / EP 的专辑名统一带「 - Single」「 - EP」后缀(各商店一致,不随界面语言变)。
func albumHintIsSingleOrEP(album string) bool {
	a := strings.ToLower(strings.TrimSpace(album))
	return strings.HasSuffix(a, " - single") || strings.HasSuffix(a, " - ep")
}

// albumHintHasEditionQualifier:「(Deluxe Edition)」「(2018 Remaster)」「(豪华版)」这类再版 / 加料版,只作
// 平手时的减分项 —— 同一张专辑的原版和豪华版都对上时,取名字最朴素的那张。
func albumHintHasEditionQualifier(album string) bool {
	a := strings.ToLower(album)
	for _, m := range []string{"deluxe", "edition", "remaster", "expanded", "anniversary", "bonus", "reissue", "豪华", "纪念版", "复刻"} {
		if strings.Contains(a, m) {
			return true
		}
	}
	return false
}

// lyricResolvedArtists:歌词链路核实过的"这首歌到底是谁的",给 pickAppleAlbumHint 的 1 档当旁证。两处来源:
//   - enrich 条目的 CanonicalArtist(网易云 / QQ 曲库核实过的官方歌手名);
//   - 已采纳的歌词决策(LyricsDecisionApplied)里**胜出候选**所报的 artist(王子 那首:kugou 候选报「Prince」)。
//
// 只读内存里的 enrich 缓存、不发请求;条目还没解析出来就返回空 —— appleAlbumHint 每拍重挑,晚几秒到也没事。
func lyricResolvedArtists(artist, title, album string) []string {
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok {
		if alt, found := canonicalEnrichKey(key); found {
			e, ok = enrichCache[alt]
		}
	}
	enrichMu.Unlock()
	if !ok {
		return nil
	}
	var out []string
	if e.CanonicalArtist != "" {
		out = append(out, e.CanonicalArtist)
	}
	if d := e.LyricsDecisionApplied; d != nil && d.Winner != "" {
		for _, c := range d.Candidates {
			if c.Source == d.Winner && strings.TrimSpace(c.Artist) != "" {
				out = append(out, c.Artist)
				break
			}
		}
	}
	return out
}
