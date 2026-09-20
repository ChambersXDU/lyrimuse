package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type neteaseInfo struct {
	Cover, SongURL, Lyrics, Trans, Roma, YRC string

	DurationSecs float64

	Artist string

	Title, Album string

	SongID int64

	AlbumID int64

	PureMusic bool
}

const (
	neteaseCacheTTL        = 30 * 24 * time.Hour
	neteaseCacheTTLNoCover = 10 * time.Minute
)

type neteaseCacheEntry struct {
	info neteaseInfo
	ts   int64
}

var (
	neteaseMu    sync.Mutex
	neteaseCache = map[string]neteaseCacheEntry{}

	neteaseLastFailureMu     sync.Mutex
	neteaseLastFailureReason string
)

const neteaseMinIntervalBetweenCalls = 250 * time.Millisecond

const (
	neteaseBlockCooldownBase = 2 * time.Minute
	neteaseBlockCooldownMax  = 15 * time.Minute
)

var (
	neteaseRateMu        sync.Mutex
	neteaseLastCall      time.Time
	neteaseCooldownUntil = map[string]time.Time{}

	neteaseBlockStreak = map[string]int{}

	neteaseAnySuccess bool
)

const (
	neteaseSearchEndpointPrimary  = "https://music.163.com/api/search/get"
	neteaseSearchEndpointFallback = "https://music.163.com/api/search/get/web"
)

func neteaseEndpointBucket(rawURL string) string {
	if u, err := neturl.Parse(rawURL); err == nil && u.Path != "" {
		return u.Path
	}
	return rawURL
}

func neteaseReportBlocked(rawURL string, cooldown time.Duration) {
	bucket := neteaseEndpointBucket(rawURL)
	target := time.Now().Add(cooldown)
	neteaseRateMu.Lock()
	if existing, ok := neteaseCooldownUntil[bucket]; !ok || target.After(existing) {
		neteaseCooldownUntil[bucket] = target
	}
	neteaseRateMu.Unlock()
}

func neteaseReportRejected(rawURL string) (time.Duration, int) {
	bucket := neteaseEndpointBucket(rawURL)
	neteaseRateMu.Lock()
	neteaseBlockStreak[bucket]++
	streak := neteaseBlockStreak[bucket]
	neteaseRateMu.Unlock()
	neteaseReportBlocked(rawURL, neteaseCooldownForStreak(streak))
	return neteaseCooldownForStreak(streak), streak
}

func neteaseCooldownForStreak(streak int) time.Duration {
	if streak < 1 {
		streak = 1
	}
	if streak >= 4 {
		return neteaseBlockCooldownMax
	}
	if scaled := neteaseBlockCooldownBase << (streak - 1); scaled < neteaseBlockCooldownMax {
		return scaled
	}
	return neteaseBlockCooldownMax
}

func neteaseReportSuccess(rawURL string) {
	bucket := neteaseEndpointBucket(rawURL)
	neteaseRateMu.Lock()
	delete(neteaseBlockStreak, bucket)
	delete(neteaseCooldownUntil, bucket)
	neteaseAnySuccess = true
	neteaseRateMu.Unlock()
}

func neteaseSawSuccessNow() bool {
	neteaseRateMu.Lock()
	defer neteaseRateMu.Unlock()
	return neteaseAnySuccess
}

var errNeteaseBucketCooling = errors.New("netease: endpoint bucket cooling down")

func neteaseThrottle(ctx context.Context, rawURL string) error {
	bucket := neteaseEndpointBucket(rawURL)
	for {
		neteaseRateMu.Lock()
		now := time.Now()

		if until, ok := neteaseCooldownUntil[bucket]; ok && until.After(now) {
			neteaseRateMu.Unlock()
			return errNeteaseBucketCooling
		}
		wait := neteaseMinIntervalBetweenCalls - now.Sub(neteaseLastCall)
		if wait <= 0 {
			neteaseLastCall = now
			neteaseRateMu.Unlock()
			return nil
		}
		neteaseRateMu.Unlock()
		select {
		case <-time.After(wait):

		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func neteaseSetLastFailureReason(reason string) {
	neteaseLastFailureMu.Lock()
	neteaseLastFailureReason = reason
	neteaseLastFailureMu.Unlock()
}

func neteaseLastFailureReasonNow() string {
	neteaseLastFailureMu.Lock()
	defer neteaseLastFailureMu.Unlock()
	return neteaseLastFailureReason
}

func neteaseLookup(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	return withholdImpersonatorRiddenIdentity(artist, neteaseLookupAll(ctx, artist, title, album, durationSecs))
}

func withholdImpersonatorRiddenIdentity(artist string, info neteaseInfo) neteaseInfo {
	if !isNeteaseImpersonatorRidden(artist) {
		return info
	}

	return neteaseInfo{
		Lyrics:       info.Lyrics,
		Trans:        info.Trans,
		Roma:         info.Roma,
		YRC:          info.YRC,
		SongID:       info.SongID,
		Title:        info.Title,
		Album:        info.Album,
		DurationSecs: info.DurationSecs,
	}
}

func neteaseLookupAll(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	if title == "" {
		return neteaseInfo{}
	}
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(durationSecs))
	now := time.Now().Unix()
	neteaseMu.Lock()
	if e, ok := neteaseCache[key]; ok {
		ttl := int64(neteaseCacheTTL / time.Second)
		if e.info.Cover == "" {
			ttl = int64(neteaseCacheTTLNoCover / time.Second)
		}
		if now-e.ts < ttl {
			neteaseMu.Unlock()
			return e.info
		}
	}
	neteaseMu.Unlock()

	info := resolveNeteaseInfo(ctx, artist, title, album, durationSecs)

	if info.SongURL != "" && (info.Cover != "" || info.Lyrics != "") {
		neteaseMu.Lock()
		neteaseCache[key] = neteaseCacheEntry{info: info, ts: now}
		neteaseMu.Unlock()
	}
	return info
}

func neteaseSearch(get func(string, any) error, q string, out any) error {
	escaped := neturl.QueryEscape(q)
	const query = "?type=1&limit=30&s="
	err := get(neteaseSearchEndpointPrimary+query+escaped, out)
	if err == nil {
		return nil
	}
	return get(neteaseSearchEndpointFallback+query+escaped, out)
}

func isInstrumentalPlaceholderLyric(lrc string) bool {
	if strings.TrimSpace(lrc) == "" {
		return false
	}
	hasPlaceholder := false
	for _, line := range strings.Split(lrc, "\n") {
		body := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if body == "" {
			continue
		}
		if strings.Contains(body, neteaseInstrumentalPlaceholderMarker) {
			hasPlaceholder = true
			continue
		}

		if isCreditLine(body) {
			continue
		}
		return false
	}
	return hasPlaceholder
}

func stripNeteaseEscapedApostrophes(s string) string {
	if !strings.Contains(s, `\'`) {
		return s
	}
	return strings.ReplaceAll(s, `\'`, "'")
}

type neSearchSong struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Artists []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Album struct {
		Name string `json:"name"`

		ID int64 `json:"id"`
	} `json:"album"`

	Duration float64 `json:"duration"`
}

func neteasePickSong(songs []neSearchSong, artist, title, album string, durationSecs float64) *neSearchSong {
	type cand struct {
		s  *neSearchSong
		sc int
	}
	var exactCands, looseCands []cand
	for i := range songs {
		s := &songs[i]
		if !lyricTitleAccepted(s.Name, title) {
			continue
		}
		artistMatch := false
		for _, a := range s.Artists {
			if artistMatches(a.Name, artist) {
				artistMatch = true
				break
			}
		}
		if !artistMatch {
			continue
		}
		sc := albumScore(s.Album.Name, album)
		if normLoose(s.Name) == normLoose(title) {
			exactCands = append(exactCands, cand{s, sc})
		} else {
			looseCands = append(looseCands, cand{s, sc})
		}
	}

	if durationSecs > 0 {
		all := append(append([]cand{}, exactCands...), looseCands...)
		var anchor *neSearchSong
		anchorSc := -1
		for _, c := range all {
			if !sameRecordingDespiteVersionTags(title, album, durationSecs, c.s.Name, c.s.Album.Name, c.s.Duration/1000) {
				continue
			}
			switch {
			case c.sc > anchorSc:
				anchor, anchorSc = c.s, c.sc
			case c.sc == anchorSc:
				anchor = nil
			}
		}
		if anchor != nil && anchorSc >= 1 {
			strictlyHighest := true
			for _, c := range all {
				if c.s != anchor && c.sc >= anchorSc {
					strictlyHighest = false
					break
				}
			}
			if strictlyHighest {
				return anchor
			}
		}
	}

	bestOf := func(cands []cand, strict bool) *neSearchSong {
		if len(cands) == 1 && !(strict && album != "" && cands[0].sc == 0) {
			return cands[0].s
		}

		var best *neSearchSong
		bestSc := 0
		for _, c := range cands {
			if album != "" && c.sc == 0 {
				continue
			}
			if best == nil || c.sc > bestSc {
				best, bestSc = c.s, c.sc
			}
		}
		return best
	}

	if len(exactCands) > 0 {
		if c := bestOf(exactCands, false); c != nil {
			return c
		}
	}

	if len(looseCands) > 0 {
		return bestOf(looseCands, true)
	}
	return nil
}

func resolveNeteaseInfo(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo {
	cli := lyricHTTPClient(4 * time.Second)
	get := func(u string, v any) error {
		if err := neteaseThrottle(ctx, u); err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", resp.StatusCode)
		}

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		var probe struct {
			Code int `json:"code"`
		}

		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {

			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (bucket rejected %d times in a row)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {

				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return fmt.Errorf("netease api code %d", probe.Code)
		}

		neteaseReportSuccess(u)
		return json.Unmarshal(body, v)
	}

	ct := stripParens(title)

	ca := stripParens(artist)
	var queries []string

	if album != "" {
		queries = append(queries, ca+" "+ct+" "+album)
	}
	queries = append(queries, ca+" "+ct)
	if ct != title {
		queries = append(queries, ca+" "+title)
	}
	queries = append(queries, ct+" "+ca)
	type neSong = neSearchSong

	pick := func(songs []neSong) *neSong {
		if lyricSearchItemsTap != nil {
			lyricSearchItemsTap("netease", artist, title, album, durationSecs, songs)
		}
		return neteasePickSong(songs, artist, title, album, durationSecs)
	}

	nameOnlyMatch := func(songs []neSong) string {
		var found string
		n := 0
		for i := range songs {
			s := &songs[i]
			if normLoose(s.Name) != normLoose(title) || albumScore(s.Album.Name, album) < 200 || len(s.Artists) != 1 {
				continue
			}
			n++
			found = s.Artists[0].Name
		}
		if n == 1 {
			return found
		}
		return ""
	}

	var chosen *neSong
	var nameOnlyArtist string
	for _, q := range queries {
		var r struct {
			Result struct {
				Songs []neSong `json:"songs"`
			} `json:"result"`
		}
		if err := neteaseSearch(get, q, &r); err != nil {
			continue
		}
		if c := pick(r.Result.Songs); c != nil {

			if chosen == nil || albumScore(c.Album.Name, album) > albumScore(chosen.Album.Name, album) {
				chosen = c
			}
			if albumScore(c.Album.Name, album) >= 200 {
				break
			}
		}

		if nameOnlyArtist == "" && len(artistCreditParts(artist)) < 2 && !isNeteaseImpersonatorRidden(artist) {
			nameOnlyArtist = nameOnlyMatch(r.Result.Songs)
		}
	}

	if chosen == nil && album != "" && durationSecs > 0 {
		if albumID, found := neteaseAlbumIDByName(ctx, artist, album); found {
			if tracks, ok := neteaseAlbumTracks(albumID); ok {
				if t, ok := anchorAlbumTrackForLocalTitle(tracks, artist, title, durationSecs); ok {
					var anchored neSong
					anchored.ID = t.neteaseSongID
					anchored.Name = t.title
					anchored.Album.Name = t.neteaseAlbum
					anchored.Album.ID = albumID
					anchored.Duration = t.duration * 1000
					if t.artist != "" {
						anchored.Artists = make([]struct {
							Name string `json:"name"`
						}, 1)
						anchored.Artists[0].Name = t.artist
					}
					chosen = &anchored
				}
			}
		}
	}
	if chosen == nil {
		if nameOnlyArtist != "" {
			return neteaseInfo{Artist: nameOnlyArtist}
		}
		return neteaseInfo{}
	}
	id := chosen.ID
	info := neteaseInfo{
		SongURL:      fmt.Sprintf("https://music.163.com/song?id=%d", id),
		Title:        chosen.Name,
		Album:        chosen.Album.Name,
		AlbumID:      chosen.Album.ID,
		DurationSecs: chosen.Duration / 1000,
	}

	if len(artistCreditParts(artist)) < 2 {
		for _, a := range chosen.Artists {
			if artistMatches(a.Name, artist) {
				info.Artist = a.Name
				break
			}
		}
	}
	var dr struct {
		Songs []struct {
			Album struct {
				PicURL string `json:"picUrl"`
			} `json:"album"`
		} `json:"songs"`
	}
	if err := get(fmt.Sprintf("https://music.163.com/api/song/detail?ids=[%d]", id), &dr); err == nil && len(dr.Songs) > 0 && dr.Songs[0].Album.PicURL != "" {

		info.Cover = dr.Songs[0].Album.PicURL + "?param=800y800"
	}

	fetchBundle := func(songID int64) (lrc, tr, roma string, pureMusic bool) {
		var r struct {
			Lrc struct {
				Lyric string `json:"lyric"`
			} `json:"lrc"`
			Tlyric struct {
				Lyric string `json:"lyric"`
			} `json:"tlyric"`
			Romalrc struct {
				Lyric string `json:"lyric"`
			} `json:"romalrc"`

			PureMusic bool `json:"pureMusic"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric?id=%d&lv=-1&kv=-1&tv=-1&rv=-1", songID), &r); err != nil {
			return "", "", "", false
		}
		return stripNeteaseEscapedApostrophes(r.Lrc.Lyric),
			stripNeteaseEscapedApostrophes(r.Tlyric.Lyric),
			stripNeteaseEscapedApostrophes(r.Romalrc.Lyric),
			r.PureMusic
	}
	fetchYRC := func(songID int64) string {
		var r struct {
			Yrc struct {
				Lyric string `json:"lyric"`
			} `json:"yrc"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric/v1?id=%d&yv=-1", songID), &r); err != nil {
			return ""
		}
		if y := stripNeteaseEscapedApostrophes(r.Yrc.Lyric); strings.Contains(y, "[") && len(y) < 40000 {
			return y
		}
		return ""
	}
	info.SongID = id
	lrc, tr, roma, pureMusic := fetchBundle(id)

	info.PureMusic = pureMusic || isInstrumentalPlaceholderLyric(lrc)
	if isTimedLRC(lrc) {
		info.Lyrics = lrc
		if isTimedLRC(tr) {
			info.Trans = tr
		}
		if isTimedLRC(roma) {
			info.Roma = roma
		}
		info.YRC = fetchYRC(id)
	}
	return info
}

func neteaseAlbumTracks(albumID int64) ([]albumTrack, bool) {
	if albumID <= 0 {
		return nil, false
	}
	cli := lyricHTTPClient(6 * time.Second)

	type neAlbumSong struct {
		ID       int64   `json:"id"`
		Name     string  `json:"name"`
		Duration float64 `json:"duration"`
		DT       float64 `json:"dt"`
		Artists  []struct {
			Name string `json:"name"`
		} `json:"artists"`
		Ar []struct {
			Name string `json:"name"`
		} `json:"ar"`
	}
	var payload struct {
		Code  int `json:"code"`
		Album struct {
			Name  string        `json:"name"`
			Size  int           `json:"size"`
			Songs []neAlbumSong `json:"songs"`
		} `json:"album"`
		Songs []neAlbumSong `json:"songs"`
	}
	fetch := func(u string) bool {

		if err := neteaseThrottle(context.Background(), u); err != nil {
			return false
		}
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Cookie", "os=pc")
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return false
		}
		payload = struct {
			Code  int `json:"code"`
			Album struct {
				Name  string        `json:"name"`
				Size  int           `json:"size"`
				Songs []neAlbumSong `json:"songs"`
			} `json:"album"`
			Songs []neAlbumSong `json:"songs"`
		}{}
		if json.NewDecoder(resp.Body).Decode(&payload) != nil {
			return false
		}

		if payload.Code != 0 && payload.Code != 200 {
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (bucket rejected %d times in a row)",
				neteaseEndpointBucket(u), payload.Code, cooldown, streak)
			return false
		}
		neteaseReportSuccess(u)
		return true
	}
	if !fetch(fmt.Sprintf("https://music.163.com/api/album/%d", albumID)) {
		if !fetch(fmt.Sprintf("https://music.163.com/api/v1/album/%d", albumID)) {
			return nil, false
		}
	}
	songs := payload.Album.Songs
	if len(songs) == 0 {
		songs = payload.Songs
	}
	if len(songs) == 0 {
		return nil, false
	}
	out := make([]albumTrack, 0, len(songs))
	for _, s := range songs {
		if s.Name == "" {
			continue
		}

		artists := s.Artists
		if len(artists) == 0 {
			artists = s.Ar
		}
		names := make([]string, 0, len(artists))
		for _, a := range artists {
			if a.Name != "" {
				names = append(names, a.Name)
			}
		}
		dur := s.Duration
		if dur <= 0 {
			dur = s.DT
		}
		out = append(out, albumTrack{
			title:    s.Name,
			artist:   strings.Join(names, " & "),
			duration: dur / 1000,

			neteaseSongID: s.ID,
			neteaseAlbum:  payload.Album.Name,
		})
	}
	return out, len(out) > 0
}

func neteaseAlbumIDByName(ctx context.Context, artist, album string) (int64, bool) {

	q := stripParens(artist) + " " + album
	get := func(u string) (int64, bool, bool) {
		if err := neteaseThrottle(ctx, u); err != nil {
			return 0, false, false
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return 0, false, false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(lyricHTTPClient(4*time.Second), req)
		if err != nil {
			return 0, false, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return 0, false, false
		}
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return 0, false, false
		}
		var probe struct {
			Code int `json:"code"`
		}
		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {

			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (bucket rejected %d times in a row)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {
				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return 0, false, false
		}
		neteaseReportSuccess(u)
		var out struct {
			Result struct {
				Albums []struct {
					ID     int64  `json:"id"`
					Name   string `json:"name"`
					Artist struct {
						Name string `json:"name"`
					} `json:"artist"`
				} `json:"albums"`
			} `json:"result"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return 0, false, false
		}

		bestID := int64(0)
		bestScore := -1
		for _, a := range out.Result.Albums {
			if !artistMatches(a.Artist.Name, artist) {
				continue
			}
			s := albumScore(a.Name, album)
			if s >= 100 && s > bestScore {
				bestID, bestScore = a.ID, s
			}
		}
		if bestID != 0 {
			return bestID, true, true
		}
		return 0, false, true
	}
	const query = "?type=10&limit=5&s="
	if id, ok, succeeded := get(neteaseSearchEndpointPrimary + query + neturl.QueryEscape(q)); succeeded {
		return id, ok
	}
	id, ok, _ := get(neteaseSearchEndpointFallback + query + neturl.QueryEscape(q))
	return id, ok
}

const retryTitleFromAlbumMaxDurationDiffSecs = 2.0

func retryTitleFromAlbum(ctx context.Context, artist, album string, durationSecs float64) string {
	title, _, _ := retryTitleFromAlbumDetailed(ctx, artist, album, durationSecs)
	return title
}

func retryTitleFromAlbumDetailed(ctx context.Context, artist, album string, durationSecs float64) (title string, diff float64, ok bool) {
	if album == "" || durationSecs <= 0 {
		return "", 0, false
	}
	albumID, found := neteaseAlbumIDByName(ctx, artist, album)
	if !found {
		return "", 0, false
	}
	tracks, found := neteaseAlbumTracks(albumID)
	if !found {
		return "", 0, false
	}
	return bestAlbumTrackByDurationDetailed(tracks, durationSecs)
}

func retryTitleFromArtistSearch(ctx context.Context, artist, title string, durationSecs float64) string {
	found, _, _ := retryTitleFromArtistSearchDetailed(ctx, artist, title, durationSecs)
	return found
}

func retryTitleFromArtistSearchDetailed(ctx context.Context, artist, title string, durationSecs float64) (found string, diff float64, ok bool) {
	if artist == "" || title == "" || durationSecs <= 0 {
		return "", 0, false
	}

	q := stripParens(artist) + " " + stripParens(title)
	type neSearchSong struct {
		Name     string  `json:"name"`
		Duration float64 `json:"duration"`
		Artists  []struct {
			Name string `json:"name"`
		} `json:"artists"`
	}
	get := func(u string) ([]albumTrack, bool) {
		if err := neteaseThrottle(ctx, u); err != nil {
			return nil, false
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(lyricHTTPClient(4*time.Second), req)
		if err != nil {
			return nil, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, false
		}
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, false
		}
		var probe struct {
			Code int `json:"code"`
		}

		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {
			cooldown, streak := neteaseReportRejected(u)
			log.Printf("netease: %s rejected (code %d), backing off %s (bucket rejected %d times in a row)",
				neteaseEndpointBucket(u), probe.Code, cooldown, streak)
			if probe.Code == 405 {
				neteaseSetLastFailureReason(lyricFailureReasonNeteaseRateLimited)
			}
			return nil, false
		}
		neteaseReportSuccess(u)
		var out struct {
			Result struct {
				Songs []neSearchSong `json:"songs"`
			} `json:"result"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return nil, false
		}
		tracks := make([]albumTrack, 0, len(out.Result.Songs))
		for _, s := range out.Result.Songs {
			if s.Name == "" {
				continue
			}
			matched := false
			for _, a := range s.Artists {
				if artistMatches(a.Name, artist) {
					matched = true
					break
				}
			}
			if !matched {
				continue
			}
			tracks = append(tracks, albumTrack{title: s.Name, artist: artist, duration: s.Duration / 1000})
		}
		return tracks, true
	}
	const query = "?type=1&limit=30&s="
	tracks, reqOK := get(neteaseSearchEndpointPrimary + query + neturl.QueryEscape(q))
	if !reqOK {
		tracks, reqOK = get(neteaseSearchEndpointFallback + query + neturl.QueryEscape(q))
		if !reqOK {
			return "", 0, false
		}
	}
	return bestAlbumTrackByDurationDetailed(topSearchRanked(tracks, retryTitleFromArtistSearchMaxRank), durationSecs)
}

const retryTitleFromArtistSearchMaxRank = 5

func topSearchRanked(tracks []albumTrack, n int) []albumTrack {
	if n <= 0 || len(tracks) <= n {
		return tracks
	}
	return tracks[:n]
}

func bestAlbumTrackByDuration(tracks []albumTrack, durationSecs float64) string {
	title, _, ok := bestAlbumTrackByDurationDetailed(tracks, durationSecs)
	if !ok {
		return ""
	}
	return title
}

func anchorAlbumTrackForLocalTitle(tracks []albumTrack, artist, title string, durationSecs float64) (albumTrack, bool) {
	var best albumTrack
	bestDiff := math.Inf(1)
	found := false
	ambiguous := false
	for _, t := range tracks {

		if t.neteaseSongID <= 0 || t.title == "" || t.duration <= 0 {
			continue
		}
		if !lyricTitleAccepted(t.title, title) {
			continue
		}
		if t.artist != "" && !artistMatches(t.artist, artist) {
			continue
		}
		d := math.Abs(t.duration - durationSecs)
		if d > retryTitleFromAlbumMaxDurationDiffSecs {
			continue
		}
		switch {
		case d < bestDiff:
			best, bestDiff, found, ambiguous = t, d, true, false
		case d == bestDiff && normLoose(t.title) != normLoose(best.title):
			ambiguous = true
		}
	}
	if !found || ambiguous {
		return albumTrack{}, false
	}
	return best, true
}

const bestAlbumTrackAmbiguityMarginSecs = 0.5

func bestAlbumTrackByDurationDetailed(tracks []albumTrack, durationSecs float64) (title string, diff float64, ok bool) {
	best := ""
	bestDiff := math.Inf(1)

	runnerDiff := math.Inf(1)
	for _, t := range tracks {
		if t.title == "" || t.duration <= 0 {
			continue
		}
		d := math.Abs(t.duration - durationSecs)
		if d > retryTitleFromAlbumMaxDurationDiffSecs {
			continue
		}
		switch {
		case d < bestDiff:

			if best != "" && normLoose(best) != normLoose(t.title) && bestDiff < runnerDiff {
				runnerDiff = bestDiff
			}
			best, bestDiff = t.title, d
		case normLoose(t.title) != normLoose(best) && d < runnerDiff:
			runnerDiff = d
		}
	}
	if best == "" {
		return "", 0, false
	}
	if runnerDiff-bestDiff <= bestAlbumTrackAmbiguityMarginSecs {
		return "", 0, false
	}
	return best, bestDiff, true
}
