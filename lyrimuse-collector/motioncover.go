package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- Apple Music Motion Artwork (motion cover) ----
//
// Extracts looping animated album covers available for select albums in Apple Music.
// The collector resolves motion assets and persists them in enrich cache; selection,
// download, and playback are handled in the Swift frontend (MotionCoverManifest.swift / MotionCoverStore.swift).
//
// Discovery mechanism:
//
//	GET https://music.apple.com/{storefront}/album/x/{collectionID}
//	  -> <script type="application/json" id="serialized-server-data">
//	  -> .../videoArtwork/dictionary/motionDetailSquare = { "video": <master m3u8>, "previewFrame": {...} }
//
// Three essential architectural invariants:
//  1. Query strictly by verified collection ID: IDs come from verified catalog anchors
//     (appleCatalogAlbumIDFor via media-control uniqueIdentifier). Textual search guessing
//     is prohibited to prevent assigning motion artwork from an unrelated album version.
//  2. Node ownership validation: parseMotionCover verifies that the candidate videoArtwork
//     node shares an ancestor subtree with storeAdamID == targetID, ensuring assets belong
//     to the queried album rather than recommendations on the same page.
//  3. Negative result caching: Albums lacking motion artwork are persisted with Checked=true
//     to prevent redundant page downloads across successive tracks of the same album.
const (
	// motionCoverStorefront specifies the Apple storefront queried, aligned with appleCatalogLookup.
	motionCoverStorefront = "cn"
	// motionCoverTimeout defines the HTTP timeout for fetching the album page.
	motionCoverTimeout = 12 * time.Second
	// motionCoverMaxPageBytes limits maximum page read size to prevent unbounded memory usage.
	motionCoverMaxPageBytes = 8 << 20
)

// motionCover represents motion artwork assets for an album. An empty Master with Checked=true
// indicates the album was verified to have no motion assets available.
type motionCover struct {
	// Master is the square (1:1) master m3u8 playlist URL.
	// Kept as master rather than fixed .mp4 to allow frontend rendition selection based on display dimensions.
	Master string `json:"master,omitempty"`
	// PreviewFrame is the URL template for the static preview frame (with {w}x{h}bb.{f} placeholders).
	// Used as placeholder while video assets load, and serves as an authoritative high-resolution album cover.
	PreviewFrame string `json:"preview_frame,omitempty"`
	// Official palette hex colors (without #) provided by Apple Catalog.
	BgColor   string `json:"bg_color,omitempty"`
	TextColor string `json:"text_color,omitempty"`
	// Checked indicates whether this collection ID has been looked up.
	Checked bool `json:"checked"`
}

var (
	motionCoverMu       sync.Mutex
	motionCoverCache    = map[string]motionCover{} // key = 十进制 collection id
	motionCoverPath     string                     // 空 = 只用内存(单测/一次性子命令)
	motionCoverDirty    bool
	motionCoverInflight = map[int64]bool{}
)

// loadMotionCoverCache / saveMotionCoverCache:整份 map 序列化 + 临时文件原子改名,跟
// loadAppleCatalogCache 同一套。
func loadMotionCoverCache(path string) {
	motionCoverMu.Lock()
	motionCoverPath = path
	motionCoverMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]motionCover
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		motionCoverMu.Lock()
		motionCoverCache = m
		motionCoverMu.Unlock()
		withMotion := 0
		for _, v := range m {
			if v.Master != "" {
				withMotion++
			}
		}
		log.Printf("cache: loaded %d motion-cover entries (%d with video) from %s", len(m), withMotion, path)
	}
}

func saveMotionCoverCache() {
	motionCoverMu.Lock()
	if !motionCoverDirty || motionCoverPath == "" {
		motionCoverMu.Unlock()
		return
	}
	data, err := json.Marshal(motionCoverCache)
	motionCoverDirty = false
	path := motionCoverPath
	motionCoverMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
	}
}

// motionCoverFor:取这张专辑的动态封面资源。缓存命中(包括"查过了没有")直接返回,不发请求。
//
// 第二个返回值是"这个 ID 已经有定论"——`false` 表示这一轮没查成(在飞、或者请求失败),调用方
// 该原样跳过,下一首歌再试。
func motionCoverFor(ctx context.Context, collectionID int64) (motionCover, bool) {
	if collectionID <= 0 {
		return motionCover{}, false
	}
	key := fmt.Sprint(collectionID)
	motionCoverMu.Lock()
	if c, ok := motionCoverCache[key]; ok {
		motionCoverMu.Unlock()
		return c, true
	}
	if motionCoverInflight[collectionID] {
		motionCoverMu.Unlock()
		return motionCover{}, false
	}
	motionCoverInflight[collectionID] = true
	motionCoverMu.Unlock()

	defer func() {
		motionCoverMu.Lock()
		delete(motionCoverInflight, collectionID)
		motionCoverMu.Unlock()
	}()

	page, err := fetchAlbumPage(ctx, collectionID)
	if err != nil {
		// 请求失败**不写缓存**:跟"这张没有"是两件事,下次还该再试。
		log.Printf("motion-cover: album %d fetch failed: %v", collectionID, err)
		return motionCover{}, false
	}
	mc, _ := parseMotionCover(page, key)
	mc.Checked = true

	motionCoverMu.Lock()
	motionCoverCache[key] = mc
	motionCoverDirty = true
	motionCoverMu.Unlock()
	// 立刻落盘,跟 appleCatalogLookup 一样:这份缓存最重要的作用是"别为同一张专辑反复抓
	// 330 KB 的页面",进程被杀之前没写盘就白查了。
	saveMotionCoverCache()
	if mc.Master != "" {
		log.Printf("motion-cover: album %d has motion artwork", collectionID)
	}
	return mc, true
}

// motionCoverPreviewSide:拿首帧去比指纹时用的边长。
//
// 600 不是随手取的:aHash 之前先被 loadCoverImage 降到 64px 见方,再大只是白下字节;而 600
// 又是这个项目里各源封面的常见档(网易云 800 / QQ 800 / Apple 600),同档比同档最稳。
const motionCoverPreviewSide = 600

// motionCoverPreviewSizedURL 把 previewFrame 的模板换成真地址。
//
// Apple 给的是 `…/{w}x{h}bb.{f}` 这种占位模板(跟它的 artwork URL 同一种形态)。模板不认就
// 原样返回 —— 调用方拿它去下载,下不到就当校验失败,不会误判成"同一张"。
func motionCoverPreviewSizedURL(tmpl string) string {
	if tmpl == "" {
		return ""
	}
	side := fmt.Sprint(motionCoverPreviewSide)
	r := strings.NewReplacer("{w}", side, "{h}", side, "{f}", "jpg")
	return r.Replace(tmpl)
}

// motionCoverMatchesCover verifies whether the motion artwork depicts the exact same cover art
// as the currently rendered track cover by comparing 8x8 average perceptual hash fingerprints.
//
// If the fingerprint Hamming distance is within coverFingerprintMaxDistance (10), the motion asset
// is confirmed to represent the current cover art, enabling safe cross-source pairing (e.g.
// NetEase or QQ cover matching an Apple motion preview frame). If images cannot be retrieved
// or decoded, returns false to prevent false positives.
func motionCoverMatchesCover(ctx context.Context, previewTmpl, coverURL string) bool {
	url := motionCoverPreviewSizedURL(previewTmpl)
	if url == "" || coverURL == "" {
		return false
	}
	previewImg := loadCoverImage(ctx, url)
	if previewImg == nil {
		return false
	}
	coverImg := loadCoverImage(ctx, coverURL)
	if coverImg == nil {
		return false
	}
	d := coverFingerprintDistance(coverFingerprint(previewImg), coverFingerprint(coverImg))
	if d > coverFingerprintMaxDistance {
		log.Printf("motion-cover: preview/cover fingerprint distance %d > %d, skipping",
			d, coverFingerprintMaxDistance)
		return false
	}
	return true
}

// motionCoverAlbumIDFromAppleURL extracts the collection ID from an enrich entry's apple_music_url
// (e.g. https://music.apple.com/cn/album/aim-high/1474635060?i=...).
//
// Used for non-Apple Music players when an Apple Music match URL is present in the enrich cache.
// Because the URL originates from text-matching search, it must be validated by motionCoverMatchesCover
// before adopting the motion artwork.
func motionCoverAlbumIDFromAppleURL(appleURL string) int64 {
	m := appleAlbumIDInURLRE.FindStringSubmatch(appleURL)
	if len(m) != 2 {
		return 0
	}
	id, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil || !appleCatalogPlausibleID(id) {
		return 0
	}
	return id
}

var appleAlbumIDInURLRE = regexp.MustCompile(`/album/[^/]*/(\d+)`)

// motionCoverWorthBackfill determines whether an existing enrich entry warrants an asynchronous
// backfill query for motion artwork (backfillPeripheralFields).
//
// Evaluated entirely against in-memory caches while holding enrichMu; never performs network I/O.
// Lock hierarchy: enrichMu -> {appleCatalogMu, motionCoverMu}.
//
// Returns true only if the track lacks motion artwork, has a candidate collection ID, and the collection
// ID has not yet been checked (or is cached with an available master asset). Cached negative results
// ("Checked: true" with no master) return false to avoid redundant background queries.
func motionCoverWorthBackfill(e enrichEntry, title, album string) bool {
	if e.MotionCoverURL != "" || e.MotionCoverChecked {
		return false
	}
	// 两条来路跟 fillMotionCover 一致(锚点优先、退到 apple_music_url),否则非 Apple Music
	// 播的存量条目连 backfill 的门都进不来。
	albumID, ok := appleCatalogAlbumIDFor(title, album)
	if !ok {
		albumID = motionCoverAlbumIDFromAppleURL(e.AppleURL)
	}
	if albumID <= 0 {
		return false
	}
	motionCoverMu.Lock()
	defer motionCoverMu.Unlock()
	mc, cached := motionCoverCache[fmt.Sprint(albumID)]
	if !cached {
		return true
	}
	return mc.Master != ""
}

var motionCoverHTTPClient = &http.Client{Timeout: motionCoverTimeout}

func fetchAlbumPage(ctx context.Context, collectionID int64) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	u := fmt.Sprintf("https://music.apple.com/%s/album/x/%d", motionCoverStorefront, collectionID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	// Emulate desktop Safari User-Agent to receive serialized-server-data JSON payload.
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "+
		"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
	resp, err := doHTTPTracked(motionCoverHTTPClient, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("http %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, motionCoverMaxPageBytes))
}

// serializedServerDataRE extracts the inline JSON payload from the HTML page.
// The raw content is parsed via encoding/json to handle escape sequences properly.
var serializedServerDataRE = regexp.MustCompile(
	`(?s)<script type="application/json" id="serialized-server-data">(.*?)</script>`)

// parseMotionCover 从专辑页里解出方形动态封面。wantID 是目标专辑的十进制 ID,用来确认拿到的
// 节点确实属于它(见文件头 ⚠️ 2)。解析不出来返回零值 + false —— 调用方据此记"这张没有"。
func parseMotionCover(page []byte, wantID string) (motionCover, bool) {
	m := serializedServerDataRE.FindSubmatch(page)
	if m == nil {
		return motionCover{}, false
	}
	var root any
	if err := json.Unmarshal(m[1], &root); err != nil {
		return motionCover{}, false
	}
	node := findVideoArtwork(root, wantID)
	if node == nil {
		return motionCover{}, false
	}
	dict, _ := node["dictionary"].(map[string]any)
	sq, _ := dict["motionDetailSquare"].(map[string]any)
	video, _ := sq["video"].(string)
	if video == "" {
		return motionCover{}, false
	}
	out := motionCover{Master: video}
	if pf, ok := sq["previewFrame"].(map[string]any); ok {
		out.PreviewFrame, _ = pf["url"].(string)
		out.BgColor, _ = pf["bgColor"].(string)
		out.TextColor, _ = pf["textColor1"].(string)
	}
	return out, true
}

// findVideoArtwork traverses the deserialized JSON structure to locate a videoArtwork node
// that belongs to wantID, verified by checking that an ancestor subtree contains storeAdamID == wantID.
func findVideoArtwork(root any, wantID string) map[string]any {
	var found map[string]any
	var walk func(v any)
	walk = func(v any) {
		if found != nil {
			return
		}
		switch t := v.(type) {
		case map[string]any:
			if va, ok := t["videoArtwork"].(map[string]any); ok && len(va) > 0 {
				// t 是 videoArtwork 的父节点(那个 item)。它的子树里该带着自己的专辑 ID。
				if subtreeHasAdamID(t, wantID) {
					found = va
					return
				}
			}
			for _, x := range t {
				walk(x)
			}
		case []any:
			for _, x := range t {
				walk(x)
			}
		}
	}
	walk(root)
	return found
}

// subtreeHasAdamID:子树里有没有 `storeAdamID == want`(Apple 的 JSON 里它是字符串)。
// 顺带认 `id` —— 同一份数据里两个键都出现过,认一个漏一个不值得。
func subtreeHasAdamID(v any, want string) bool {
	switch t := v.(type) {
	case map[string]any:
		for k, x := range t {
			if (k == "storeAdamID" || k == "id") && x == any(want) {
				return true
			}
			if subtreeHasAdamID(x, want) {
				return true
			}
		}
	case []any:
		for _, x := range t {
			if subtreeHasAdamID(x, want) {
				return true
			}
		}
	}
	return false
}
