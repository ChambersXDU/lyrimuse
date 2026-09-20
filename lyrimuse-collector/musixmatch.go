package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	musixmatchAppID   = "mac-ios-v2.0"
	musixmatchBaseURL = "https://apic-appmobile.musixmatch.com/ws/1.1/"
)

type musixmatchResult struct {
	lrc string
	yrc string
	tr  string

	title, artist, album, cover string

	durationSecs float64

	plainOnly bool

	instrumental bool
}

var (
	musixmatchMu    sync.Mutex
	musixmatchCache = map[string]musixmatchResult{}

	musixmatchTokenMu     sync.Mutex
	musixmatchToken       string
	musixmatchTokenExpiry time.Time

	musixmatchTokenFetchMu sync.Mutex

	musixmatchLastFailureMu     sync.Mutex
	musixmatchLastFailureReason string
)

func musixmatchSetLastFailureReason(reason string) {
	musixmatchLastFailureMu.Lock()
	musixmatchLastFailureReason = reason
	musixmatchLastFailureMu.Unlock()
}

func musixmatchLastFailureReasonNow() string {
	musixmatchLastFailureMu.Lock()
	defer musixmatchLastFailureMu.Unlock()
	return musixmatchLastFailureReason
}

var musixmatchDoFetchToken func(ctx context.Context) string

func musixmatchCachedToken() string {
	musixmatchTokenMu.Lock()
	defer musixmatchTokenMu.Unlock()
	if musixmatchToken != "" && time.Now().Before(musixmatchTokenExpiry) {
		return musixmatchToken
	}
	return ""
}

func musixmatchLyric(ctx context.Context, artist, title string, durationSecs float64, trLang string) musixmatchResult {
	if title == "" {
		return musixmatchResult{}
	}
	key := artist + "|" + title + "|" + trLang
	musixmatchMu.Lock()
	if v, ok := musixmatchCache[key]; ok {
		musixmatchMu.Unlock()
		return v
	}
	musixmatchMu.Unlock()

	r := resolveMusixmatchLyric(ctx, artist, title, durationSecs, trLang)
	if r.lrc != "" {
		musixmatchMu.Lock()
		musixmatchCache[key] = r
		musixmatchMu.Unlock()
	}
	return r
}

func resolveMusixmatchLyric(ctx context.Context, artist, title string, durationSecs float64, trLang string) musixmatchResult {
	_ = durationSecs
	match, ok := musixmatchSearchTrack(ctx, artist, title)
	if !ok {
		return musixmatchResult{}
	}

	if match.instrumental {
		return musixmatchResult{
			instrumental: true,
			title:        match.title,
			artist:       match.artist,
			album:        match.album,
			cover:        match.cover,
			durationSecs: match.durationSecs,
		}
	}

	var lrc string
	if match.hasSubtitles {
		lrc = musixmatchSubtitleLRC(ctx, match.trackID)
	}
	if lrc == "" {

		plain := musixmatchPlainLyrics(ctx, match.trackID)
		if plain == "" {
			return musixmatchResult{}
		}

		if isTimedLRC(plain) {
			return musixmatchResult{lrc: plain, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
		}
		return musixmatchResult{lrc: plain, plainOnly: true, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
	}

	var yrc string
	if match.hasRichsync {
		yrc = musixmatchRichsync(ctx, match.trackID)
	}
	tr := musixmatchTranslationLRC(ctx, match.trackID, lrc, trLang)
	return musixmatchResult{lrc: lrc, yrc: yrc, tr: tr, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
}

func musixmatchEnsureToken(ctx context.Context) string {
	if t := musixmatchCachedToken(); t != "" {
		return t
	}

	musixmatchTokenFetchMu.Lock()
	defer musixmatchTokenFetchMu.Unlock()
	if t := musixmatchCachedToken(); t != "" {
		return t
	}

	if t := musixmatchLoadTokenFile(); t != "" {
		return t
	}
	if musixmatchDoFetchToken != nil {
		return musixmatchDoFetchToken(ctx)
	}
	return musixmatchFetchToken(ctx, 0)
}

func musixmatchTokenPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-musixmatch-token.json")
}

type musixmatchTokenFile struct {
	Token  string `json:"token"`
	Expiry int64  `json:"expiry"`
}

func musixmatchLoadTokenFile() string {
	path := musixmatchTokenPath()
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var f musixmatchTokenFile
	if json.Unmarshal(raw, &f) != nil || f.Token == "" {
		return ""
	}
	if time.Now().Unix() >= f.Expiry {
		return ""
	}
	musixmatchTokenMu.Lock()
	musixmatchToken = f.Token
	musixmatchTokenExpiry = time.Unix(f.Expiry, 0)
	musixmatchTokenMu.Unlock()
	return f.Token
}

func musixmatchSaveTokenFile(token string, expiry time.Time) {
	path := musixmatchTokenPath()
	if path == "" {
		return
	}
	raw, err := json.Marshal(musixmatchTokenFile{Token: token, Expiry: expiry.Unix()})
	if err != nil {
		return
	}

	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if os.WriteFile(tmp, raw, 0o600) != nil {
		return
	}
	if os.Rename(tmp, path) != nil {
		os.Remove(tmp)
	}
}

func musixmatchFetchToken(ctx context.Context, retry int) string {
	if retry > 1 {
		return ""
	}
	body, err := musixmatchDo(ctx, "token.get", neturl.Values{"user_language": {"en"}})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				UserToken string `json:"user_token"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil {
		return ""
	}
	if out.Message.Header.StatusCode == 401 {

		musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchRateLimited)
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return ""
		}
		return musixmatchFetchToken(ctx, retry+1)
	}
	token := out.Message.Body.UserToken
	if token == "" {
		return ""
	}
	expiry := time.Now().Add(9 * time.Minute)
	musixmatchTokenMu.Lock()
	musixmatchToken = token
	musixmatchTokenExpiry = expiry
	musixmatchTokenMu.Unlock()
	musixmatchSaveTokenFile(token, expiry)
	return token
}

var (
	musixmatchClientOnce sync.Once
	musixmatchClient     *http.Client
)

func musixmatchHTTPClient() *http.Client {
	musixmatchClientOnce.Do(func() {

		musixmatchClient = dohHTTPClient(func() {
			musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchDirectBlocked)
		})
	})
	return musixmatchClient
}

func musixmatchDo(ctx context.Context, action string, params neturl.Values) ([]byte, error) {
	if action != "token.get" {
		if token := musixmatchEnsureToken(ctx); token != "" {
			params.Set("usertoken", token)
		}
	}
	params.Set("app_id", musixmatchAppID)
	params.Set("t", strconv.FormatInt(time.Now().UnixMilli(), 10))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, musixmatchBaseURL+action+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")

	resp, err := doHTTPTracked(musixmatchHTTPClient(), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("musixmatch %s: status %d", action, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

type musixmatchTrackMatch struct {
	trackID                     int64
	title, artist, album, cover string
	durationSecs                float64

	hasSubtitles bool

	hasRichsync bool

	instrumental bool
}

type musixmatchTrackRow struct {
	TrackID              int64  `json:"track_id"`
	TrackName            string `json:"track_name"`
	ArtistName           string `json:"artist_name"`
	AlbumName            string `json:"album_name"`
	AlbumCoverart500x500 string `json:"album_coverart_500x500"`
	HasSubtitles         int    `json:"has_subtitles"`

	HasLyrics int `json:"has_lyrics"`

	TrackLength int `json:"track_length"`

	HasRichsync  int `json:"has_richsync"`
	Instrumental int `json:"instrumental"`
}

func pickMusixmatchTrackRow(rows []musixmatchTrackRow, artist, localTitle string) (musixmatchTrackMatch, bool) {
	accept := func(r musixmatchTrackRow) bool {
		return lyricTitleAccepted(r.TrackName, localTitle) && lyricSourceArtistMatches(r.ArtistName, artist)
	}
	build := func(r musixmatchTrackRow) musixmatchTrackMatch {
		return musixmatchTrackMatch{
			trackID:      r.TrackID,
			title:        r.TrackName,
			artist:       r.ArtistName,
			album:        r.AlbumName,
			cover:        r.AlbumCoverart500x500,
			durationSecs: float64(r.TrackLength),
			hasSubtitles: r.HasSubtitles == 1,
			hasRichsync:  r.HasRichsync == 1,
		}
	}
	for _, r := range rows {
		if r.HasSubtitles == 1 && accept(r) {
			return build(r), true
		}
	}
	for _, r := range rows {
		if r.HasLyrics == 1 && accept(r) {
			return build(r), true
		}
	}
	for _, r := range rows {
		if r.Instrumental == 1 && accept(r) {
			m := build(r)
			m.instrumental = true
			return m, true
		}
	}
	return musixmatchTrackMatch{}, false
}

func musixmatchSearchTrack(ctx context.Context, artist, title string) (musixmatchTrackMatch, bool) {
	for _, q := range searchTitleVariants(title) {

		if m, ok := musixmatchSearchTrackOnce(ctx, artist, q, title); ok {
			return m, true
		}
	}
	return musixmatchTrackMatch{}, false
}

func musixmatchSearchTrackOnce(ctx context.Context, artist, queryTitle, localTitle string) (musixmatchTrackMatch, bool) {
	body, err := musixmatchDo(ctx, "track.search", neturl.Values{
		"q_artist":       {artist},
		"q_track":        {queryTitle},
		"s_track_rating": {"desc"},
		"page_size":      {"5"},
		"page":           {"1"},
	})
	if err != nil {
		return musixmatchTrackMatch{}, false
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				TrackList []struct {
					Track musixmatchTrackRow `json:"track"`
				} `json:"track_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return musixmatchTrackMatch{}, false
	}
	rows := make([]musixmatchTrackRow, 0, len(out.Message.Body.TrackList))
	for _, t := range out.Message.Body.TrackList {
		rows = append(rows, t.Track)
	}
	return pickMusixmatchTrackRow(rows, artist, localTitle)
}

func musixmatchPlainLyrics(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.lyrics.get", neturl.Values{
		"track_id": {strconv.FormatInt(trackID, 10)},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Lyrics struct {
					LyricsBody   string `json:"lyrics_body"`
					Restricted   int    `json:"restricted"`
					Instrumental int    `json:"instrumental"`
				} `json:"lyrics"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	l := out.Message.Body.Lyrics
	if l.Restricted != 0 || l.Instrumental != 0 {
		return ""
	}
	return sanitizeMusixmatchPlainLyrics(l.LyricsBody)
}

func sanitizeMusixmatchPlainLyrics(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	kept := make([]string, 0, len(lines))
	for _, ln := range lines {
		if musixmatchNoticeLine(ln) {
			break
		}
		kept = append(kept, ln)
	}

	for len(kept) > 0 {
		last := strings.TrimSpace(kept[len(kept)-1])
		if last == "" || musixmatchTrackingNumberLine(last) {
			kept = kept[:len(kept)-1]
			continue
		}
		break
	}
	return strings.TrimSpace(strings.Join(kept, "\n"))
}

func musixmatchNoticeLine(line string) bool {
	t := strings.TrimSpace(line)
	if t == "" {
		return false
	}
	if strings.Count(t, "*") >= 3 && strings.Trim(t, "*") == "" {
		return true
	}
	return strings.Contains(strings.ToLower(t), "not for commercial use")
}

func musixmatchTrackingNumberLine(t string) bool {
	if !strings.HasPrefix(t, "(") || !strings.HasSuffix(t, ")") {
		return false
	}
	inner := t[1 : len(t)-1]
	if len(inner) < 6 {
		return false
	}
	for _, r := range inner {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func musixmatchSubtitleLRC(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.subtitle.get", neturl.Values{
		"track_id":        {strconv.FormatInt(trackID, 10)},
		"subtitle_format": {"lrc"},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Subtitle struct {
					SubtitleBody string `json:"subtitle_body"`
				} `json:"subtitle"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	lrc := out.Message.Body.Subtitle.SubtitleBody
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

type musixmatchRichsyncWord struct {
	C string  `json:"c"`
	O float64 `json:"o"`
}

type musixmatchRichsyncLine struct {
	Ts float64                  `json:"ts"`
	Te float64                  `json:"te"`
	L  []musixmatchRichsyncWord `json:"l"`
}

func musixmatchRichsync(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.richsync.get", neturl.Values{
		"track_id": {strconv.FormatInt(trackID, 10)},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Richsync struct {
					RichsyncBody string `json:"richsync_body"`
				} `json:"richsync"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	raw := out.Message.Body.Richsync.RichsyncBody
	if raw == "" {
		return ""
	}
	var lines []musixmatchRichsyncLine
	if json.Unmarshal([]byte(raw), &lines) != nil || len(lines) == 0 {
		return ""
	}
	return richsyncToYRC(lines)
}

func richsyncToYRC(lines []musixmatchRichsyncLine) string {
	var b strings.Builder
	for _, ln := range lines {
		lineStartMs := int64(ln.Ts * 1000)
		lineEndMs := int64(ln.Te * 1000)
		if lineEndMs < lineStartMs {
			lineEndMs = lineStartMs
		}

		type mergedWord struct {
			startMs int64
			text    string
		}
		words := make([]mergedWord, 0, len(ln.L))
		prefix := ""
		for _, w := range ln.L {
			if strings.TrimSpace(w.C) == "" {
				if n := len(words); n > 0 {
					words[n-1].text += w.C
				} else {
					prefix += w.C
				}
				continue
			}
			words = append(words, mergedWord{lineStartMs + int64(w.O*1000), prefix + w.C})
			prefix = ""
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStartMs, lineEndMs-lineStartMs)
		for j, w := range words {
			var wordEndMs int64
			if j+1 < len(words) {
				wordEndMs = words[j+1].startMs
			} else {
				wordEndMs = lineEndMs
			}
			if wordEndMs < w.startMs {
				wordEndMs = w.startMs
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.startMs, wordEndMs-w.startMs, w.text)
		}
		b.WriteByte('\n')
	}
	return b.String()
}

type musixmatchTranslationItem struct {
	Translation struct {
		SubtitleMatchedLine string `json:"subtitle_matched_line"`
		Description         string `json:"description"`
	} `json:"translation"`
}

var musixmatchLRCLineRe = regexp.MustCompile(`^(\[\d{1,2}:\d{2}[.:]\d{1,3}\])(.*)$`)

func musixmatchTranslationLRC(ctx context.Context, trackID int64, originalLRC, lang string) string {
	if lang == "" {
		return ""
	}
	body, err := musixmatchDo(ctx, "crowd.track.translations.get", neturl.Values{
		"track_id":               {strconv.FormatInt(trackID, 10)},
		"subtitle_format":        {"lrc"},
		"translation_fields_set": {"minimal"},
		"selected_language":      {lang},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Body struct {
				TranslationsList []musixmatchTranslationItem `json:"translations_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || len(out.Message.Body.TranslationsList) == 0 {
		return ""
	}
	tr := buildTranslatedLRC(originalLRC, out.Message.Body.TranslationsList)
	if !isTimedLRC(tr) {
		return ""
	}
	return tr
}

func buildTranslatedLRC(originalLRC string, items []musixmatchTranslationItem) string {
	var parsed []struct{ ts, text string }
	for _, l := range strings.Split(strings.ReplaceAll(originalLRC, "\r\n", "\n"), "\n") {
		m := musixmatchLRCLineRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		parsed = append(parsed, struct{ ts, text string }{ts: m[1], text: strings.TrimSpace(m[2])})
	}
	var b strings.Builder
	for _, p := range parsed {
		if p.text == "" {
			continue
		}
		for _, item := range items {
			matched := strings.TrimSpace(item.Translation.SubtitleMatchedLine)
			tr := strings.TrimSpace(item.Translation.Description)
			if matched == "" || tr == "" {
				continue
			}
			if p.text == matched || strings.Contains(p.text, matched) || strings.Contains(matched, p.text) {
				b.WriteString(p.ts)
				b.WriteString(tr)
				b.WriteByte('\n')
				break
			}
		}
	}
	return b.String()
}
