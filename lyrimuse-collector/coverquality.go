package main

import (
	"context"
	"image"
	"log"
	"strings"
)

const deviceCoverTrustedMinEdge = 300

const coverFingerprintSide = 8

const coverFingerprintMaxDistance = 10

func coverFingerprint(img image.Image) uint64 {
	if img == nil {
		return 0
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 {
		return 0
	}
	cells := make([]float64, coverFingerprintSide*coverFingerprintSide)
	for cy := 0; cy < coverFingerprintSide; cy++ {
		for cx := 0; cx < coverFingerprintSide; cx++ {
			x0 := b.Min.X + w*cx/coverFingerprintSide
			x1 := b.Min.X + w*(cx+1)/coverFingerprintSide
			y0 := b.Min.Y + h*cy/coverFingerprintSide
			y1 := b.Min.Y + h*(cy+1)/coverFingerprintSide

			if x1 <= x0 {
				x1 = x0 + 1
			}
			if y1 <= y0 {
				y1 = y0 + 1
			}
			var sum float64
			var n float64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					r, g, bb, _ := img.At(x, y).RGBA()

					sum += 0.299*float64(r>>8) + 0.587*float64(g>>8) + 0.114*float64(bb>>8)
					n++
				}
			}
			if n > 0 {
				cells[cy*coverFingerprintSide+cx] = sum / n
			}
		}
	}
	var mean float64
	for _, v := range cells {
		mean += v
	}
	mean /= float64(len(cells))
	var hash uint64
	for i, v := range cells {
		if v > mean {
			hash |= 1 << uint(i)
		}
	}
	return hash
}

func coverFingerprintDistance(a, b uint64) int {
	x := a ^ b
	n := 0
	for x != 0 {
		x &= x - 1
		n++
	}
	return n
}

func coverImagesLikelySame(a, b image.Image) bool {
	if a == nil || b == nil {
		return false
	}
	fa, fb := coverFingerprint(a), coverFingerprint(b)

	if fa == 0 || fb == 0 {
		return false
	}
	return coverFingerprintDistance(fa, fb) <= coverFingerprintMaxDistance
}

func minEdge(img image.Image) int {
	if img == nil {
		return 0
	}
	b := img.Bounds()
	if b.Dx() < b.Dy() {
		return b.Dx()
	}
	return b.Dy()
}

func coverURLIntendedEdge(coverURL string) int {
	u := strings.TrimSpace(coverURL)
	if u == "" {
		return 0
	}

	if i := strings.Index(u, "?param="); i >= 0 {
		spec := u[i+len("?param="):]
		if j := strings.IndexAny(spec, "&#"); j >= 0 {
			spec = spec[:j]
		}
		for _, sep := range []string{"y", "x"} {
			if k := strings.Index(spec, sep); k > 0 {
				if n := atoiSafe(spec[:k]); n > 0 {
					return n
				}
			}
		}
		if n := atoiSafe(spec); n > 0 {
			return n
		}
		return 0
	}

	if n := edgeFromNxNSegment(u); n > 0 {
		return n
	}
	return 0
}

func edgeFromNxNSegment(u string) int {
	best := 0
	for i := 0; i < len(u); i++ {
		if u[i] != 'x' && u[i] != 'X' {
			continue
		}

		l := i
		for l > 0 && u[l-1] >= '0' && u[l-1] <= '9' {
			l--
		}

		r := i + 1
		for r < len(u) && u[r] >= '0' && u[r] <= '9' {
			r++
		}
		if l == i || r == i+1 {
			continue
		}
		a, b := atoiSafe(u[l:i]), atoiSafe(u[i+1:r])

		if a > 0 && a == b {
			best = a
		}
	}
	return best
}

func atoiSafe(s string) int {
	if s == "" || len(s) > 5 {
		return 0
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		n = n*10 + int(s[i]-'0')
	}
	return n
}

func deviceCoverDecision(
	deviceImg image.Image, candidateURL string, candidateEdge int,
	loadImage func(string) image.Image,
) (override bool, reason string) {
	if deviceImg == nil {

		return false, "设备封面解不出来"
	}
	edge := minEdge(deviceImg)
	if edge >= deviceCoverTrustedMinEdge {
		return true, "设备封面够清晰"
	}
	if strings.TrimSpace(candidateURL) == "" {
		return true, "没有远程候选"
	}
	if candidateEdge <= 0 {

		return true, "候选尺寸认不出来"
	}
	if candidateEdge <= edge {
		return true, "远程候选不比设备封面大"
	}

	cand := loadImage(candidateURL)
	if cand == nil {
		return true, "远程候选取不到/解不出来"
	}
	if coverImagesLikelySame(deviceImg, cand) {

		return false, "同一张图,改用更清晰的远程候选"
	}

	return true, "远程候选是另一张图,保留设备封面"
}

var deviceCoverUpgradable = func(deviceCoverURL, candidateURL string) bool {
	return !deviceCoverOverridesCandidate(context.Background(), deviceCoverURL, candidateURL)
}

func deviceCoverOverridesCandidate(ctx context.Context, deviceCoverURL, candidateURL string) bool {
	deviceImg := loadCoverImage(ctx, deviceCoverURL)
	override, reason := deviceCoverDecision(
		deviceImg, candidateURL, coverURLIntendedEdge(candidateURL),
		func(u string) image.Image { return loadCoverImage(ctx, u) })
	if !override {

		log.Printf("cover: device artwork %dpx yields to remote candidate %dpx (%s)",
			minEdge(deviceImg), coverURLIntendedEdge(candidateURL), reason)
	}
	return override
}
