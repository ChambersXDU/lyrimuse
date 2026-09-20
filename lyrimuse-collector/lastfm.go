package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type lastfmScrobbler struct {
	apiKey, secret, sk string
	hc                 *http.Client

	dead atomic.Bool

	suspect4 atomic.Int64

	clearStatus sync.Once

	collapse *lastfmArtistCollapser
}

func newLastfmScrobbler(apiKey, secret, sk string) *lastfmScrobbler {
	if apiKey == "" || secret == "" || sk == "" {
		return nil
	}
	return &lastfmScrobbler{apiKey: apiKey, secret: secret, sk: sk, hc: &http.Client{Timeout: 8 * time.Second}}
}

func lastfmScrobblerIfEnabled(cfg *config) *lastfmScrobbler {
	if !features.LastfmMirrorScrobble {
		return nil
	}
	s := newLastfmScrobbler(cfg.LastfmScrobbleAPIKey, cfg.LastfmScrobbleSecret, cfg.LastfmScrobbleSessionKey)
	if s != nil {

		s.collapse = newLastfmArtistCollapser(cfg.lastfmBridgeAPIKey())
	}
	return s
}

func (s *lastfmScrobbler) sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteString(params[k])
	}
	b.WriteString(s.secret)
	sum := md5.Sum([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func (s *lastfmScrobbler) call(ctx context.Context, method string, params map[string]string) error {
	p := make(map[string]string, len(params)+2)
	for k, v := range params {
		p[k] = v
	}
	p["method"] = method
	p["api_key"] = s.apiKey
	p["sk"] = s.sk
	form := neturl.Values{}
	for k, v := range p {
		form.Set(k, v)
	}
	form.Set("api_sig", s.sign(p))
	form.Set("format", "json")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://ws.audioscrobbler.com/2.0/", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", clientName)
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var out struct {
		Error     int    `json:"error"`
		Message   string `json:"message"`
		Scrobbles *struct {
			Attr struct {
				Accepted json.Number `json:"accepted"`
				Ignored  json.Number `json:"ignored"`
			} `json:"@attr"`

			Scrobble json.RawMessage `json:"scrobble"`
		} `json:"scrobbles"`
	}
	_ = json.Unmarshal(body, &out)
	if out.Error != 0 {
		return &lastfmAPIError{Code: out.Error, Message: out.Message, Method: method}
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lastfm %s: status %d: %s", method, resp.StatusCode, body)
	}

	if out.Scrobbles != nil {
		if accepted, _ := out.Scrobbles.Attr.Accepted.Int64(); accepted == 0 {
			return &lastfmIgnoredError{Method: method, Reason: ignoredReason(out.Scrobbles.Scrobble)}
		}
	}
	return nil
}

type lastfmIgnoredError struct {
	Method string
	Reason string
}

func (e *lastfmIgnoredError) Error() string {
	if e.Reason == "" {
		return fmt.Sprintf("lastfm %s: ignored by server (accepted=0)", e.Method)
	}
	return fmt.Sprintf("lastfm %s: ignored by server (accepted=0): %s", e.Method, e.Reason)
}

func ignoredReason(raw json.RawMessage) string {
	entries := parseScrobbleEntries(raw)
	reasons := make([]string, 0, len(entries))
	for _, e := range entries {
		code := strings.TrimSpace(e.IgnoredMessage.Code)
		if code == "" || code == "0" {
			continue
		}
		if text := strings.TrimSpace(e.IgnoredMessage.Text); text != "" {
			reasons = append(reasons, code+" "+text)
			continue
		}
		reasons = append(reasons, "code "+code)
	}
	return strings.Join(reasons, "; ")
}

func provablyNeverSent(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}
	var opErr *net.OpError
	return errors.As(err, &opErr) && opErr.Op == "dial"
}

type lastfmAPIError struct {
	Code    int
	Message string
	Method  string
}

func (e *lastfmAPIError) Error() string {
	return fmt.Sprintf("lastfm %s: api error %d: %s", e.Method, e.Code, e.Message)
}

func (e *lastfmAPIError) fatal() bool {
	switch e.Code {
	case 4, 9, 10, 26:
		return true
	}
	return false
}

func (e *lastfmAPIError) mayHaveStored() bool {
	switch e.Code {
	case 11, 16:
		return true
	}
	return false
}

func (s *lastfmScrobbler) shouldDisable(apiErr *lastfmAPIError, now time.Time) bool {
	if !apiErr.fatal() {
		return false
	}
	if apiErr.Code != 4 {
		return true
	}
	const confirmGap = 30 * time.Second
	const suspectWindow = 30 * time.Minute
	prev := s.suspect4.Load()
	age := time.Duration(now.UnixNano() - prev)
	if prev != 0 && age >= confirmGap && age <= suspectWindow {
		return true
	}
	if prev == 0 || age > suspectWindow {
		s.suspect4.CompareAndSwap(prev, now.UnixNano())
	}
	return false
}

func durationParam(p map[string]string, key string, durationSecs float64) {
	if durationSecs > 0 {
		p[key] = strconv.FormatInt(int64(durationSecs), 10)
	}
}

func resolveScrobbleArtist(ctx context.Context, c *lastfmArtistCollapser, artist, track string) string {
	switch features.LastfmScrobbleArtistMode {
	case scrobbleArtistFirst:
		if first := firstCreditedArtist(artist); first != "" {
			return first
		}
		return artist
	case scrobbleArtistSmart:
		return c.resolve(ctx, artist, track)
	default:
		return artist
	}
}

func mirrorTimeout() time.Duration {
	const write = 8 * time.Second
	if features.LastfmScrobbleArtistMode == scrobbleArtistSmart {
		return write + lastfmCollapseBudget
	}
	return write
}

func (s *lastfmScrobbler) updateNowPlaying(ctx context.Context, artist, track, album string, durationSecs float64) error {
	artist = resolveScrobbleArtist(ctx, s.collapse, artist, track)
	p := map[string]string{"artist": artist, "track": track}
	if album != "" {
		p["album"] = album
	}

	durationParam(p, "duration", durationSecs)
	return s.call(ctx, "track.updateNowPlaying", p)
}

func (s *lastfmScrobbler) scrobble(ctx context.Context, artist, track, album string, timestamp int64, durationSecs float64) error {

	artist = resolveScrobbleArtist(ctx, s.collapse, artist, track)
	p := map[string]string{"artist": artist, "track": track, "timestamp": strconv.FormatInt(timestamp, 10)}
	if album != "" {
		p["album"] = album
	}

	durationParam(p, "duration", durationSecs)
	return s.call(ctx, "track.scrobble", p)
}

func mirrorAsync(s *lastfmScrobbler, what string, call func(ctx context.Context) error, onFail func(error)) {
	if s == nil {
		return
	}
	if s.dead.Load() {

		if onFail != nil {
			onFail(&lastfmAPIError{Code: 9, Message: "mirror disabled (credentials judged dead)", Method: what})
		}
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), mirrorTimeout())
		defer cancel()
		err := call(ctx)
		if err == nil {

			s.suspect4.Store(0)

			s.clearStatus.Do(func() { os.Remove(lastfmStatusPath) })
			return
		}
		var apiErr *lastfmAPIError
		if errors.As(err, &apiErr) && s.shouldDisable(apiErr, time.Now()) {

			if s.dead.CompareAndSwap(false, true) {
				log.Printf("lastfm mirror DISABLED: %v (fatal credential error; reconnect the account in Lyrimuse settings to resume)", apiErr)
				writeLastfmMirrorStatus(apiErr)
			}
			return
		}
		if apiErr != nil && apiErr.fatal() {

			log.Printf("lastfm mirror %s: %v (single error 4 may be transient server flakiness; mirror stays up, disables only on recurrence)", what, apiErr)

			if onFail != nil {
				onFail(err)
			}
			return
		}
		log.Printf("lastfm mirror %s failed: %v", what, err)
		if onFail != nil {
			onFail(err)
		}
	}()
}

func writeLastfmMirrorStatus(apiErr *lastfmAPIError) {
	if lastfmStatusPath == "" {
		return
	}
	data, err := json.Marshal(struct {
		Error   int    `json:"error"`
		Message string `json:"message"`
		Method  string `json:"method"`
		At      int64  `json:"at"`
	}{apiErr.Code, apiErr.Message, apiErr.Method, time.Now().Unix()})
	if err != nil {
		return
	}
	if err := os.WriteFile(lastfmStatusPath, data, 0o644); err != nil {
		log.Printf("lastfm mirror: write status file failed: %v", err)
	}
}

type lastfmTrack struct {
	Title, Artist, Album string
	Image                string
	UTS                  int64
}

type lastfmRecentPage struct {
	NowPlaying *lastfmTrack
	Done       []lastfmTrack
	Total      int
}

func lastfmRecent(ctx context.Context, user, apiKey string) (page lastfmRecentPage, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	u := fmt.Sprintf(
		"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=%s&api_key=%s&format=json&limit=50",
		neturl.QueryEscape(user), neturl.QueryEscape(apiKey))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		log.Printf("lastfmRecent: build request: %v", err)
		return lastfmRecentPage{}, false
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		log.Printf("lastfmRecent: request failed: %v", err)
		return lastfmRecentPage{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("lastfmRecent: status %d", resp.StatusCode)
		return lastfmRecentPage{}, false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		log.Printf("lastfmRecent: read response: %v", err)
		return lastfmRecentPage{}, false
	}
	page, err = parseLastfmRecent(body)
	if err != nil {
		log.Printf("lastfmRecent: decode response: %v", err)
		return lastfmRecentPage{}, false
	}
	return page, true
}

func parseLastfmRecent(body []byte) (lastfmRecentPage, error) {
	var out struct {
		RecentTracks struct {
			Attr struct {
				Total string `json:"total"`
			} `json:"@attr"`
			Track []struct {
				Name   string `json:"name"`
				Artist struct {
					Text string `json:"#text"`
				} `json:"artist"`
				Album struct {
					Text string `json:"#text"`
				} `json:"album"`
				Image []struct {
					Size string `json:"size"`
					Text string `json:"#text"`
				} `json:"image"`
				Date struct {
					UTS string `json:"uts"`
				} `json:"date"`
				Attr struct {
					NowPlaying string `json:"nowplaying"`
				} `json:"@attr"`
			} `json:"track"`
		} `json:"recenttracks"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return lastfmRecentPage{}, err
	}
	var page lastfmRecentPage
	page.Total, _ = strconv.Atoi(out.RecentTracks.Attr.Total)
	for _, t := range out.RecentTracks.Track {
		if t.Name == "" {
			continue
		}
		tr := lastfmTrack{Title: t.Name, Artist: t.Artist.Text, Album: t.Album.Text}

		pick := func(size string) string {
			for _, im := range t.Image {
				if im.Size == size {
					return im.Text
				}
			}
			return ""
		}
		tr.Image = pick("large")
		if tr.Image == "" {
			tr.Image = pick("extralarge")
		}
		if tr.Image == "" && len(t.Image) > 0 {
			tr.Image = t.Image[len(t.Image)-1].Text
		}
		if t.Attr.NowPlaying == "true" {
			np := tr
			page.NowPlaying = &np
		} else if t.Date.UTS != "" {
			tr.UTS, _ = strconv.ParseInt(t.Date.UTS, 10, 64)
			page.Done = append(page.Done, tr)
		}
	}
	return page, nil
}
