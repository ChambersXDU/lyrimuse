package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type kugouResult struct {
	lrc string
	yrc string

	tr, roma string

	durationSecs float64

	title, artist, album string

	cover string

	language string
}

var (
	kugouMu    sync.Mutex
	kugouCache = map[string]kugouResult{}
)

func kugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {
	if title == "" {
		return kugouResult{}
	}

	key := artist + "|" + title + "|" + album
	kugouMu.Lock()
	if v, ok := kugouCache[key]; ok {
		kugouMu.Unlock()
		return v
	}
	kugouMu.Unlock()

	r := resolveKugouLyric(ctx, artist, title, album, durationSecs)
	if r.lrc != "" {
		kugouMu.Lock()
		kugouCache[key] = r
		kugouMu.Unlock()
	}
	return r
}

var krcXORKey = []byte{0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69}

func decryptKRC(b64 string) string {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) <= 4 {
		return ""
	}
	body := raw[4:]
	dec := make([]byte, len(body))
	for i, b := range body {
		dec[i] = b ^ krcXORKey[i%len(krcXORKey)]
	}
	zr, err := zlib.NewReader(bytes.NewReader(dec))
	if err != nil {
		return ""
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		return ""
	}
	return string(out)
}

var (
	krcLineRegex = regexp.MustCompile(`^(\[(\d+),\d+\])(.*)$`)
	krcWordRegex = regexp.MustCompile(`<(\d+),(\d+),(\d+)>`)
)

func krcToYRC(krc string) string {
	if krc == "" {
		return ""
	}
	normalized := strings.ReplaceAll(krc, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for i, line := range lines {
		m := krcLineRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		lineStart, err := strconv.Atoi(m[2])
		if err != nil {
			continue
		}
		body := krcWordRegex.ReplaceAllStringFunc(m[3], func(match string) string {
			wm := krcWordRegex.FindStringSubmatch(match)
			wordStart, _ := strconv.Atoi(wm[1])
			return fmt.Sprintf("(%d,%s,%s)", lineStart+wordStart, wm[2], wm[3])
		})
		lines[i] = m[1] + body
	}
	return strings.Join(lines, "\n")
}

var krcLanguageLineRegex = regexp.MustCompile(`^\[language:(.*)\]$`)

const krcLanguageRomaMaxHanRatio = 0.3

func splitKRCLanguageLine(krc string) (b64, rest string) {
	normalized := strings.ReplaceAll(strings.ReplaceAll(krc, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for i, line := range lines {
		if m := krcLanguageLineRegex.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			return strings.TrimSpace(m[1]), strings.Join(append(lines[:i:i], lines[i+1:]...), "\n")
		}
	}
	return "", normalized
}

func krcLineStarts(krc string) []int {
	var starts []int
	for _, line := range strings.Split(krc, "\n") {
		m := krcLineRegex.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil || !strings.HasPrefix(strings.TrimSpace(m[3]), "<") {
			continue
		}
		start, err := strconv.Atoi(m[2])
		if err != nil {
			continue
		}
		starts = append(starts, start)
	}
	return starts
}

func krcLanguageTracks(b64, krc string) (tr, roma string) {
	if b64 == "" {
		return "", ""
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", ""
	}
	var payload struct {
		Content []struct {
			Type         int        `json:"type"`
			LyricContent [][]string `json:"lyricContent"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", ""
	}
	starts := krcLineStarts(krc)
	for _, track := range payload.Content {
		switch track.Type {
		case 1:
			if tr == "" {
				tr = krcLanguageTrackToLRC(track.LyricContent, starts)
			}
		case 0:
			if roma == "" {
				roma = krcLanguageTrackToLRC(track.LyricContent, starts)
			}
		}
	}
	if roma != "" && cjkRatio(roma) > krcLanguageRomaMaxHanRatio {
		roma = ""
	}
	return tr, roma
}

func krcLanguageTrackToLRC(content [][]string, starts []int) string {
	if len(content) == 0 || len(content) != len(starts) {
		return ""
	}
	var out []string
	for i, fragments := range content {
		text := strings.Join(strings.Fields(strings.Join(fragments, "")), " ")
		if text == "" || text == "//" {
			continue
		}
		ms := starts[i]
		out = append(out, fmt.Sprintf("[%02d:%02d.%03d]%s", ms/60000, (ms/1000)%60, ms%1000, text))
	}
	lrc := strings.Join(out, "\n")
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

type kugouSong struct {
	Hash       string  `json:"hash"`
	SongName   string  `json:"songname"`
	SingerName string  `json:"singername"`
	AlbumName  string  `json:"album_name"`
	AlbumID    string  `json:"album_id"`
	Duration   float64 `json:"duration"`

	TransParam struct {
		Language string `json:"language"`
	} `json:"trans_param"`
}

func kugouCanonicalLanguage(s string) string {
	switch s {
	case "国语":
		return songLanguageMandarin
	case "粤语":
		return songLanguageCantonese
	default:
		return ""
	}
}

func kugouEscape(s string) string {
	return strings.ReplaceAll(neturl.QueryEscape(s), "+", "%20")
}

func kugouGet(ctx context.Context, u string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func resolveKugouLyric(ctx context.Context, artist, title, album string, durationSecs float64) kugouResult {

	var chosen *kugouSong
	for _, q := range searchTitleVariants(title) {
		var sr struct {
			Data struct {
				Info []kugouSong `json:"info"`
			} `json:"data"`
		}
		if err := kugouGet(ctx, "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword="+kugouEscape(artist+" "+q)+"&page=1&pagesize=10&showtype=1", &sr); err != nil {
			continue
		}
		if lyricSearchItemsTap != nil {
			lyricSearchItemsTap("kugou", artist, title, album, durationSecs, sr.Data.Info)
		}
		chosen = pickKugouSearchCandidate(sr.Data.Info, artist, title, album, durationSecs)
		if chosen != nil {
			break
		}
	}
	if chosen == nil {
		return kugouResult{}
	}
	durMs := int64(chosen.Duration * 1000)
	if durMs <= 0 && durationSecs > 0 {
		durMs = int64(durationSecs * 1000)
	}
	var kr struct {
		Candidates []struct {
			ID        string `json:"id"`
			AccessKey string `json:"accesskey"`
		} `json:"candidates"`
	}
	krcURL := fmt.Sprintf("http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=%s&duration=%d&hash=%s",
		kugouEscape(artist+" - "+title), durMs, chosen.Hash)
	if err := kugouGet(ctx, krcURL, &kr); err != nil || len(kr.Candidates) == 0 {
		return kugouResult{}
	}
	c := kr.Candidates[0]
	if c.ID == "" || c.AccessKey == "" {
		return kugouResult{}
	}
	var dl struct {
		Content string `json:"content"`
	}
	dlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=lrc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(ctx, dlURL, &dl); err != nil || dl.Content == "" {
		return kugouResult{}
	}
	raw, err := base64.StdEncoding.DecodeString(dl.Content)
	if err != nil {
		return kugouResult{}
	}
	lrc := string(raw)
	if !isTimedLRC(lrc) {
		return kugouResult{}
	}

	var yrc, tr, roma string
	var krcDl struct {
		Content string `json:"content"`
	}
	krcDlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=krc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(ctx, krcDlURL, &krcDl); err == nil && krcDl.Content != "" {
		if decrypted := decryptKRC(krcDl.Content); decrypted != "" {

			lang, body := splitKRCLanguageLine(decrypted)
			yrc = krcToYRC(body)
			tr, roma = krcLanguageTracks(lang, body)
		}
	}
	return kugouResult{lrc: lrc, yrc: yrc, tr: tr, roma: roma, durationSecs: chosen.Duration, title: chosen.SongName, artist: chosen.SingerName, album: chosen.AlbumName, language: kugouCanonicalLanguage(chosen.TransParam.Language), cover: kugouAlbumCoverURL(ctx, chosen.AlbumID)}
}

func pickKugouSearchCandidate(songs []kugouSong, artist, title, album string, durationSecs float64) *kugouSong {
	const (
		tierExact = iota
		tierStripped
		tierAccepted
	)
	nt := normLoose(title)
	st := normLoose(stripParens(title))
	var best *kugouSong
	bestTier, bestAlbum := 0, 0
	bestDur := math.Inf(1)
	bestByTriangle, bestFits := false, false
	for i := range songs {
		s := &songs[i]

		if s.Hash == "" || !lyricTitleAccepted(s.SongName, title) {
			continue
		}
		byTriangle := false
		if !lyricSourceArtistMatches(s.SingerName, artist) {

			if !lyricRecordingTriangleMatches(s.SongName, s.AlbumName, s.Duration,
				title, album, durationSecs) {
				continue
			}
			byTriangle = true
		}
		tier := tierAccepted
		switch {
		case normLoose(s.SongName) == nt:
			tier = tierExact
		case normLoose(stripParens(s.SongName)) == st:
			tier = tierStripped
		}
		asc := albumScore(s.AlbumName, album)
		dd := math.Inf(1)
		if durationSecs > 0 && s.Duration > 0 {
			dd = math.Abs(s.Duration - durationSecs)
		}

		fits := sourceDurationFits(durationSecs, s.Duration)
		better := false
		switch {
		case best == nil:
			better = true
		case fits != bestFits:
			better = fits
		case tier != bestTier:
			better = tier < bestTier
		case asc != bestAlbum:
			better = asc > bestAlbum
		case dd != bestDur:
			better = dd < bestDur
		}
		if better {
			best, bestTier, bestAlbum, bestDur, bestByTriangle, bestFits = s, tier, asc, dd, byTriangle, fits
		}
	}

	if best != nil && bestByTriangle {
		log.Printf("lyrics: kugou accepted %q by recording triangle (local artist %q vs source %q; album %q vs %q; dur %.3f vs %.3f)",
			best.SongName, artist, best.SingerName, album, best.AlbumName, durationSecs, best.Duration)
	}
	return best
}

func kugouAlbumCoverURL(ctx context.Context, albumID string) string {
	if albumID == "" {
		return ""
	}
	var out struct {
		Data struct {
			ImgURL string `json:"imgurl"`
		} `json:"data"`
	}
	u := "http://mobilecdn.kugou.com/api/v3/album/info?albumid=" + neturl.QueryEscape(albumID)
	if err := kugouGet(ctx, u, &out); err != nil || out.Data.ImgURL == "" {
		return ""
	}
	cover := strings.ReplaceAll(out.Data.ImgURL, "{size}", "480")

	return strings.Replace(cover, "http://", "https://", 1)
}
