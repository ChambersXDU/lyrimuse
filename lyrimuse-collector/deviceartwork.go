package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"image"
	"math"
	"os"
	"path/filepath"
)

const (

	deviceArtworkMinEdge = 64

	deviceArtworkMaxAspectSkew = 0.15
)

var deviceArtworkDir string

func decodeDeviceArtwork(data []byte) (image.Image, bool) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, false
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w < deviceArtworkMinEdge || h < deviceArtworkMinEdge {
		return nil, false
	}
	longer := math.Max(float64(w), float64(h))
	if math.Abs(float64(w-h))/longer > deviceArtworkMaxAspectSkew {
		return nil, false
	}
	return img, true
}

func deviceCoverURLIfFresh(ctx context.Context, isNewTrack bool, bundleID, artist, title string) string {
	if !isNewTrack {
		return ""
	}
	data, mimeType, ok := fetchNowPlayingArtwork(ctx, bundleID, artist, title)
	if !ok {
		return ""
	}
	if _, ok := decodeDeviceArtwork(data); !ok {
		return ""
	}
	url, ok := saveDeviceArtwork(data, mimeType)
	if !ok {
		return ""
	}
	return url
}

func saveDeviceArtwork(data []byte, mimeType string) (string, bool) {
	if deviceArtworkDir == "" {
		return "", false
	}
	ext := ".jpg"
	if mimeType == "image/png" {
		ext = ".png"
	}
	sum := sha256.Sum256(data)
	path := filepath.Join(deviceArtworkDir, hex.EncodeToString(sum[:8])+ext)
	if _, err := os.Stat(path); err == nil {
		return "file://" + path, true
	}
	if err := os.MkdirAll(deviceArtworkDir, 0o755); err != nil {
		return "", false
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", false
	}
	return "file://" + path, true
}
