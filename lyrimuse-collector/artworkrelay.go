package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (

	artworkRelayPath = "/artwork/"

	artworkMaxUploadBytes = 1024 * 1024

	artworkUploadRetryAfter = 5 * time.Minute

	artworkSweepGap = 300 * time.Millisecond
)

var (
	artworkRelayURL   string
	artworkRelayToken string
)

var (
	artworkMu sync.Mutex

	artworkUploaded = map[string]bool{}
	artworkInflight = map[string]bool{}

	artworkNextRetry = map[string]time.Time{}
)

func deviceArtworkRef(coverURL string) (sha, path string, ok bool) {
	if !strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		return "", "", false
	}
	path = strings.TrimPrefix(coverURL, deviceArtworkURLPrefix)
	ext := strings.ToLower(filepath.Ext(path))
	if ext != ".jpg" && ext != ".png" {
		return "", "", false
	}
	stem := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if !isHex16(stem) {
		return "", "", false
	}
	return stem, path, true
}

func isHex16(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func artworkContentType(path string) string {
	if strings.EqualFold(filepath.Ext(path), ".png") {
		return "image/png"
	}
	return "image/jpeg"
}

func artworkPublicURL(sha, path string) string {
	return strings.TrimRight(artworkRelayURL, "/") + artworkRelayPath + sha + strings.ToLower(filepath.Ext(path))
}

func webSafeCoverURL(coverURL string) string {
	if coverURL == "" || !strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		return coverURL
	}
	sha, path, ok := deviceArtworkRef(coverURL)
	if !ok || artworkRelayURL == "" {
		return ""
	}
	artworkMu.Lock()
	uploaded := artworkUploaded[sha]
	artworkMu.Unlock()
	if uploaded {
		return artworkPublicURL(sha, path)
	}
	scheduleArtworkUpload(sha, path)
	return ""
}

func scheduleArtworkUpload(sha, path string) {
	artworkMu.Lock()
	if artworkInflight[sha] || time.Now().Before(artworkNextRetry[sha]) {
		artworkMu.Unlock()
		return
	}
	artworkInflight[sha] = true
	artworkMu.Unlock()

	go func() {
		err := ensureArtworkUploaded(context.Background(), sha, path)
		artworkMu.Lock()
		delete(artworkInflight, sha)
		if err == nil {
			artworkUploaded[sha] = true
		} else {
			artworkNextRetry[sha] = time.Now().Add(artworkUploadRetryAfter)
		}
		artworkMu.Unlock()
		if err != nil {
			log.Printf("artwork relay: upload failed sha=%s, not retrying for %v: %v", sha, artworkUploadRetryAfter, err)
		}
	}()
}

func ensureArtworkUploaded(ctx context.Context, sha, path string) error {
	if artworkRelayURL == "" {
		return fmt.Errorf("artwork relay: 未配置中继地址")
	}
	url := artworkPublicURL(sha, path)
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil); err == nil {
		if resp, err := doHTTPTracked(http.DefaultClient, req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}

	}

	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > artworkMaxUploadBytes {
		return fmt.Errorf("artwork %s: %d 字节,不在允许范围内", sha, len(data))
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", artworkContentType(path))
	req.Header.Set("x-token", artworkRelayToken)
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("artwork upload %s: status %d", sha, resp.StatusCode)
	}
	return nil
}

func sweepDeviceArtwork(ctx context.Context) {
	if artworkRelayURL == "" || deviceArtworkDir == "" {
		return
	}
	entries, err := os.ReadDir(deviceArtworkDir)
	if err != nil {
		return
	}
	uploaded, failed, skipped := 0, 0, 0
	for _, ent := range entries {
		if ctx.Err() != nil {
			return
		}
		if ent.IsDir() {
			continue
		}
		path := filepath.Join(deviceArtworkDir, ent.Name())
		sha, _, ok := deviceArtworkRef(deviceArtworkURLPrefix + path)
		if !ok {
			skipped++
			continue
		}
		artworkMu.Lock()
		done := artworkUploaded[sha]
		artworkMu.Unlock()
		if done {
			continue
		}
		if err := ensureArtworkUploaded(ctx, sha, path); err != nil {
			failed++
			log.Printf("artwork relay: backfill upload failed sha=%s: %v", sha, err)
		} else {
			artworkMu.Lock()
			artworkUploaded[sha] = true
			artworkMu.Unlock()
			uploaded++
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(artworkSweepGap):
		}
	}
	if uploaded > 0 || failed > 0 {
		log.Printf("artwork relay: startup backfill done confirmed=%d failed=%d skipped=%d", uploaded, failed, skipped)
	}
}
