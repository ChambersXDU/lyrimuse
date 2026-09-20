package main

import (
	"log/slog"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	networkAttemptCount int32
	networkFailureCount int32
)

func doHTTPTracked(cli *http.Client, req *http.Request) (*http.Response, error) {

	var (
		traceMu sync.Mutex
		trace   transportTrace
	)
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
		DNSStart: func(httptrace.DNSStartInfo) {
			traceMu.Lock()
			trace.dnsStarted = true
			traceMu.Unlock()
		},
		DNSDone: func(info httptrace.DNSDoneInfo) {
			traceMu.Lock()
			trace.dnsDone = true
			trace.dnsErr = info.Err
			traceMu.Unlock()
		},
	}))
	start := time.Now()
	resp, err := cli.Do(req)
	elapsed := time.Since(start)
	traceMu.Lock()
	tr := trace
	traceMu.Unlock()
	atomic.AddInt32(&networkAttemptCount, 1)

	target := req.Method + " " + req.URL.Host + req.URL.Path

	summaryKey := req.Method + " " + req.URL.Host + normalizeAuditPath(req.URL.Path)
	if m := req.URL.Query().Get("method"); m != "" {
		target += " method=" + m
		summaryKey += " method=" + m
	}
	if err != nil {
		atomic.AddInt32(&networkFailureCount, 1)

		safeErr := any(err)
		if ue, ok := err.(*url.Error); ok {
			safeErr = ue.Err
		}

		slog.Warn("api call: "+target+" FAILED", "elapsed_ms", elapsed.Milliseconds(), "err", safeErr)
		recordAPICall(summaryKey, elapsed, true, time.Now())

		noteLyricRoundFailure(req.Context(), req.URL.Host, err, 0)
		lyricSourceBreakerShared.observeTraced(req.URL.Host, err, 0, "", tr)
		return resp, err
	}
	noteLyricRoundFailure(req.Context(), req.URL.Host, nil, resp.StatusCode)
	lyricSourceBreakerShared.observeTraced(req.URL.Host, nil, resp.StatusCode, resp.Header.Get("Retry-After"), tr)
	failed := resp.StatusCode >= 400
	if failed {
		slog.Warn("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	} else {

		slog.Debug("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	}
	recordAPICall(summaryKey, elapsed, failed, time.Now())
	return resp, err
}

const apiCallSummaryWindow = time.Minute

func normalizeAuditPath(p string) string {
	segs := strings.Split(p, "/")
	for i, seg := range segs {
		base, ext := seg, ""
		if dot := strings.LastIndexByte(seg, '.'); dot > 0 && len(seg)-dot <= 5 {
			base, ext = seg[:dot], seg[dot:]
		}
		switch {
		case base == "":
		case isUUIDToken(base):
			segs[i] = "<uuid>" + ext
		case len(base) >= 8 && allInSet(base, "0123456789abcdefABCDEF"):
			segs[i] = "<hex>" + ext
		case len(base) >= 3 && allInSet(base, "0123456789"):
			segs[i] = "<n>" + ext
		case len(base) >= 24 && strings.ContainsAny(base, "0123456789"):
			segs[i] = "<id>" + ext
		}
	}
	return strings.Join(segs, "/")
}

func allInSet(s, set string) bool {
	for _, r := range s {
		if !strings.ContainsRune(set, r) {
			return false
		}
	}
	return true
}

func isUUIDToken(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
				return false
			}
		}
	}
	return true
}

type apiCallWindow struct {
	first, last time.Time
	count       int
	failed      int
	durations   []time.Duration
}

var apiCallAgg = struct {
	mu      sync.Mutex
	windows map[string]*apiCallWindow
}{windows: map[string]*apiCallWindow{}}

func recordAPICall(target string, elapsed time.Duration, failed bool, now time.Time) {
	apiCallAgg.mu.Lock()
	defer apiCallAgg.mu.Unlock()
	w := apiCallAgg.windows[target]
	if w == nil {
		w = &apiCallWindow{first: now}
		apiCallAgg.windows[target] = w
	}
	w.last = now
	w.count++
	if failed {
		w.failed++
	}
	w.durations = append(w.durations, elapsed)
}

func flushAPICallSummaries(now time.Time, force bool) {
	apiCallAgg.mu.Lock()
	type done struct {
		target string
		w      *apiCallWindow
	}
	var ready []done
	for target, w := range apiCallAgg.windows {
		if !force && now.Sub(w.first) < apiCallSummaryWindow {
			continue
		}
		ready = append(ready, done{target, w})
		delete(apiCallAgg.windows, target)
	}
	apiCallAgg.mu.Unlock()
	sort.Slice(ready, func(i, j int) bool { return ready[i].target < ready[j].target })
	for _, d := range ready {
		sort.Slice(d.w.durations, func(i, j int) bool { return d.w.durations[i] < d.w.durations[j] })
		p50 := d.w.durations[len(d.w.durations)/2]
		max := d.w.durations[len(d.w.durations)-1]
		slog.Info("api call summary",
			"target", d.target,
			"count", d.w.count,
			"failed", d.w.failed,
			"p50_ms", p50.Milliseconds(),
			"max_ms", max.Milliseconds(),
			"span_s", int(d.w.last.Sub(d.w.first).Round(time.Second).Seconds()))
	}
}

func networkLooksDown() bool {
	attempts := atomic.LoadInt32(&networkAttemptCount)
	failures := atomic.LoadInt32(&networkFailureCount)
	return attempts >= 3 && failures == attempts
}

func beginNetworkRound() func() (attempts, failures int32) {
	a0 := atomic.LoadInt32(&networkAttemptCount)
	f0 := atomic.LoadInt32(&networkFailureCount)
	return func() (int32, int32) {
		return atomic.LoadInt32(&networkAttemptCount) - a0,
			atomic.LoadInt32(&networkFailureCount) - f0
	}
}

func roundLooksNetworkDown(attempts, failures int32) bool {
	return attempts >= 3 && failures == attempts
}

func lyricsRoundConfirmsNoResult(attempts, failures int32) bool {
	return attempts > 0 && failures < attempts
}
