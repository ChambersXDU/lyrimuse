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

const (

	motionCoverStorefront = "cn"

	motionCoverTimeout = 12 * time.Second

	motionCoverMaxPageBytes = 8 << 20
)

type motionCover struct {

	Master string `json:"master,omitempty"`

	PreviewFrame string `json:"preview_frame,omitempty"`

	BgColor   string `json:"bg_color,omitempty"`
	TextColor string `json:"text_color,omitempty"`

	Checked bool `json:"checked"`
}

var (
	motionCoverMu       sync.Mutex
	motionCoverCache    = map[string]motionCover{}
	motionCoverPath     string
	motionCoverDirty    bool
	motionCoverInflight = map[int64]bool{}
)

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

		log.Printf("motion-cover: album %d fetch failed: %v", collectionID, err)
		return motionCover{}, false
	}
	mc, _ := parseMotionCover(page, key)
	mc.Checked = true

	motionCoverMu.Lock()
	motionCoverCache[key] = mc
	motionCoverDirty = true
	motionCoverMu.Unlock()

	saveMotionCoverCache()
	if mc.Master != "" {
		log.Printf("motion-cover: album %d has motion artwork", collectionID)
	}
	return mc, true
}

const motionCoverPreviewSide = 600

func motionCoverPreviewSizedURL(tmpl string) string {
	if tmpl == "" {
		return ""
	}
	side := fmt.Sprint(motionCoverPreviewSide)
	r := strings.NewReplacer("{w}", side, "{h}", side, "{f}", "jpg")
	return r.Replace(tmpl)
}

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

func motionCoverWorthBackfill(e enrichEntry, title, album string) bool {
	if e.MotionCoverURL != "" || e.MotionCoverChecked {
		return false
	}

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

var serializedServerDataRE = regexp.MustCompile(
	`(?s)<script type="application/json" id="serialized-server-data">(.*?)</script>`)

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
