package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (

	backfillBatchSize = 50

	backfillBatchPause = 2 * time.Second

	backfillMaxAge = 13 * 24 * time.Hour

	backfillRequestTimeout = 30 * time.Second
)

type backfillItem struct {
	UTS    int64   `json:"uts"`
	Artist string  `json:"artist"`
	Title  string  `json:"title"`
	Album  string  `json:"album,omitempty"`
	Dur    float64 `json:"dur,omitempty"`
}

type backfillOutcome struct {

	Items []backfillItem `json:"items,omitempty"`

	Eligible int `json:"eligible"`

	Accepted int `json:"accepted"`

	Ignored int `json:"ignored"`

	SkippedTooOld int `json:"skippedTooOld"`

	Quarantined int `json:"quarantined"`

	AbortedReason string `json:"abortedReason,omitempty"`
}

func pendingBackfillListens(now time.Time) (pending []listenLogLine, tooOld int) {
	lines := readListenLog()
	listens := make(map[int64]listenLogLine, len(lines))
	submitted := make(map[int64]bool, len(lines))
	for _, l := range lines {
		switch l.T {
		case "l":
			if l.UTS > 0 && l.TI != "" {
				listens[l.UTS] = l

				if l.M == 1 {
					submitted[l.UTS] = true
				}
			}
		case "s":
			if l.UTS > 0 {
				submitted[l.UTS] = true
			}
		case "q":

			if l.UTS > 0 {
				submitted[l.UTS] = true
			}
		}
	}
	cutoff := now.Add(-backfillMaxAge).Unix()
	for uts, l := range listens {
		if submitted[uts] {
			continue
		}

		if tooShortToScrobble(l.DUR) {
			continue
		}
		if uts < cutoff {
			tooOld++
			continue
		}
		pending = append(pending, l)
	}
	sort.Slice(pending, func(i, j int) bool { return pending[i].UTS < pending[j].UTS })
	return pending, tooOld
}

func markBackfilled(uts int64) {
	appendListenLogLine(listenLogLine{
		T: "s", V: listenLogSchemaVersion, UTS: uts, AT: time.Now().Unix(),
	})
}

type scrobbleBatchResult struct {
	accepted map[int64]bool
	ignored  map[int64]string
}

func (s *lastfmScrobbler) scrobbleBatch(ctx context.Context, items []listenLogLine) (*scrobbleBatchResult, error) {
	if len(items) == 0 {
		return &scrobbleBatchResult{accepted: map[int64]bool{}, ignored: map[int64]string{}}, nil
	}
	if len(items) > backfillBatchSize {
		return nil, fmt.Errorf("scrobbleBatch: %d items exceeds the %d limit", len(items), backfillBatchSize)
	}

	p := map[string]string{}
	for i, it := range items {

		artist := resolveScrobbleArtist(ctx, s.collapse, it.AR, it.TI)
		idx := strconv.Itoa(i)
		p["artist["+idx+"]"] = artist
		p["track["+idx+"]"] = it.TI
		p["timestamp["+idx+"]"] = strconv.FormatInt(it.UTS, 10)
		if it.AL != "" {
			p["album["+idx+"]"] = it.AL
		}

		durationParam(p, "duration["+idx+"]", it.DUR)
	}

	return s.callBatch(ctx, "track.scrobble", p)
}

func (s *lastfmScrobbler) callBatch(ctx context.Context, method string, params map[string]string) (*scrobbleBatchResult, error) {
	p := make(map[string]string, len(params)+3)
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

	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://ws.audioscrobbler.com/2.0/", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", clientName)
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {

		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var envelope struct {
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
	_ = json.Unmarshal(body, &envelope)
	if envelope.Error != 0 {
		return nil, &lastfmAPIError{Code: envelope.Error, Message: envelope.Message, Method: method}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("lastfm %s: status %d", method, resp.StatusCode)
	}
	if envelope.Scrobbles == nil {
		return nil, fmt.Errorf("lastfm %s: response has no scrobbles element", method)
	}

	out := &scrobbleBatchResult{accepted: map[int64]bool{}, ignored: map[int64]string{}}
	for _, e := range parseScrobbleEntries(envelope.Scrobbles.Scrobble) {
		uts, err := strconv.ParseInt(strings.TrimSpace(e.Timestamp), 10, 64)
		if err != nil || uts <= 0 {
			continue
		}
		code := strings.TrimSpace(e.IgnoredMessage.Code)
		if code == "" || code == "0" {
			out.accepted[uts] = true
			continue
		}
		msg := strings.TrimSpace(e.IgnoredMessage.Text)
		if msg == "" {
			msg = "ignored code " + code
		}
		out.ignored[uts] = msg
	}
	return out, nil
}

type scrobbleEntry struct {
	Timestamp      string `json:"timestamp"`
	IgnoredMessage struct {
		Code string `json:"code"`
		Text string `json:"#text"`
	} `json:"ignoredMessage"`
}

func parseScrobbleEntries(raw json.RawMessage) []scrobbleEntry {
	if len(raw) == 0 {
		return nil
	}
	var many []scrobbleEntry
	if err := json.Unmarshal(raw, &many); err == nil {
		return many
	}
	var one scrobbleEntry
	if err := json.Unmarshal(raw, &one); err == nil {
		return []scrobbleEntry{one}
	}
	log.Printf("backfill: could not parse scrobble entries: %s", truncateForLog(raw))
	return nil
}

func truncateForLog(b []byte) string {
	const max = 200
	if len(b) <= max {
		return string(b)
	}
	return string(b[:max]) + "…"
}

func markQuarantined(uts int64) {
	appendListenLogLine(listenLogLine{
		T: "q", V: listenLogSchemaVersion, UTS: uts, AT: time.Now().Unix(),
	})
}

func runBackfill(ctx context.Context, s *lastfmScrobbler, dryRun bool) backfillOutcome {
	now := time.Now()
	pending, tooOld := pendingBackfillListens(now)
	out := backfillOutcome{Eligible: len(pending), SkippedTooOld: tooOld}

	if dryRun {

		out.Items = make([]backfillItem, 0, len(pending))
		for i := len(pending) - 1; i >= 0; i-- {
			l := pending[i]
			out.Items = append(out.Items, backfillItem{
				UTS: l.UTS, Artist: l.AR, Title: l.TI, Album: l.AL, Dur: l.DUR,
			})
		}
		return out
	}
	if s == nil {
		out.AbortedReason = "last.fm not configured"
		return out
	}
	if len(pending) == 0 {
		return out
	}

	log.Printf("backfill: %d listen(s) to submit (%d too old to accept)", len(pending), tooOld)
	for start := 0; start < len(pending); start += backfillBatchSize {
		end := min(start+backfillBatchSize, len(pending))
		batch := pending[start:end]

		res, err := s.scrobbleBatch(ctx, batch)
		if err != nil {

			var apiErr *lastfmAPIError
			definitelyNotStored := errors.As(err, &apiErr) && !apiErr.mayHaveStored()
			if definitelyNotStored {
				out.AbortedReason = err.Error()
				log.Printf("backfill: aborted, %d listen(s) stay pending (server refused, nothing stored): %v", len(batch), err)
				return out
			}

			for _, it := range batch {
				markQuarantined(it.UTS)
				out.Quarantined++
			}
			out.AbortedReason = err.Error()
			log.Printf("backfill: aborted after quarantining %d listen(s): %v", len(batch), err)
			return out
		}

		for _, it := range batch {
			switch {
			case res.accepted[it.UTS]:
				markBackfilled(it.UTS)
				out.Accepted++
			case res.ignored[it.UTS] != "":

				markBackfilled(it.UTS)
				out.Ignored++
				log.Printf("backfill: ignored by server: %s - %s (%s)", it.AR, it.TI, res.ignored[it.UTS])
			default:

				markQuarantined(it.UTS)
				out.Quarantined++
			}
		}

		if end < len(pending) {
			select {
			case <-time.After(backfillBatchPause):
			case <-ctx.Done():
				out.AbortedReason = "cancelled"
				return out
			}
		}
	}
	log.Printf("backfill: done — accepted=%d ignored=%d quarantined=%d tooOld=%d",
		out.Accepted, out.Ignored, out.Quarantined, out.SkippedTooOld)
	if out.Accepted > 0 {

		touchLastfmFeedNudgeFile()
	}
	return out
}
