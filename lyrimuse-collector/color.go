package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"math"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

var (
	accentMu                 sync.Mutex
	accentCache              = map[string]string{}
	coverDownloadHTTPClient = &http.Client{Timeout: 4 * time.Second}
)

func dominantColor(ctx context.Context, coverURL string) string {
	if coverURL == "" {
		return ""
	}
	accentMu.Lock()
	if v, ok := accentCache[coverURL]; ok {
		accentMu.Unlock()
		return v
	}
	accentMu.Unlock()
	c := resolveDominantColor(ctx, coverURL)
	if c != "" {
		accentMu.Lock()
		accentCache[coverURL] = c
		accentMu.Unlock()
	}
	return c
}

const deviceArtworkURLPrefix = "file://"

func resolveDominantColor(ctx context.Context, coverURL string) string {
	img := loadCoverImage(ctx, coverURL)
	if img == nil {
		return ""
	}
	return dominantColorFromImage(img)
}

func loadCoverImage(ctx context.Context, coverURL string) image.Image {
	if strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		data, err := os.ReadFile(strings.TrimPrefix(coverURL, deviceArtworkURLPrefix))
		if err != nil {
			return nil
		}
		img, _, err := image.Decode(bytes.NewReader(data))
		if err != nil {
			return nil
		}
		return img
	}
	small := coverURL
	referer := "https://music.163.com/"
	if strings.Contains(coverURL, "music.126.net") || strings.Contains(coverURL, "music.127.net") {
		if i := strings.Index(small, "?param="); i >= 0 {
			small = small[:i]
		}
		small += "?param=64y64"
	} else if strings.Contains(coverURL, "qq.com") {

		small = qqCoverAtEdge(small, "300")
		referer = "https://y.qq.com/"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, small, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Referer", referer)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(coverDownloadHTTPClient, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	img, _, err := image.Decode(resp.Body)
	if err != nil {
		return nil
	}
	return img
}

func dominantColorFromImage(img image.Image) string {
	b := img.Bounds()
	var wr, wg, wb, wsum float64
	var ar, ag, ab, n float64
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			r16, g16, b16, _ := img.At(x, y).RGBA()
			r, g, bl := float64(r16>>8), float64(g16>>8), float64(b16>>8)
			ar, ag, ab, n = ar+r, ag+g, ab+bl, n+1
			mx := math.Max(r, math.Max(g, bl))
			mn := math.Min(r, math.Min(g, bl))
			sat := 0.0
			if mx > 0 {
				sat = (mx - mn) / mx
			}
			w := sat * sat
			wr, wg, wb, wsum = wr+r*w, wg+g*w, wb+bl*w, wsum+w
		}
	}
	if n == 0 {
		return ""
	}
	var r, g, bl float64
	if wsum > 0.5 {
		r, g, bl = wr/wsum, wg/wsum, wb/wsum
	} else {
		r, g, bl = ar/n, ag/n, ab/n
	}

	return fmt.Sprintf("#%02x%02x%02x", int(r+0.5), int(g+0.5), int(bl+0.5))
}
