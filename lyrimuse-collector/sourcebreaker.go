package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var lyricSourceBreakerSchedule = []time.Duration{
	15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute,
}

const (

	lyricSourceBreakerTripAfter = 2

	lyricSourceBreakerRetryAfterDefault = time.Minute
	lyricSourceBreakerRetryAfterMax     = 5 * time.Minute
)

const (
	lyricSourceCooldownReasonNetwork     = "network"
	lyricSourceCooldownReasonServerError = "http_5xx"
	lyricSourceCooldownReasonRateLimited = "http_429"
)

type lyricSourceBreakerState struct {
	until       time.Time
	consecutive int

	trips  int
	reason string
}

type lyricSourceBreaker struct {
	mu    sync.Mutex
	now   func() time.Time
	state map[string]*lyricSourceBreakerState

	transport map[string]*lyricSourceTransportState
}

func newLyricSourceBreaker(now func() time.Time) *lyricSourceBreaker {
	return &lyricSourceBreaker{
		now:       now,
		state:     map[string]*lyricSourceBreakerState{},
		transport: map[string]*lyricSourceTransportState{},
	}
}

var lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)

func lyricSourceForHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	switch {
	case h == "music.163.com" || strings.HasSuffix(h, ".163.com"):
		return "netease"
	case h == "qq.com" || strings.HasSuffix(h, ".qq.com"):
		return "qq"
	case h == "kugou.com" || strings.HasSuffix(h, ".kugou.com"):
		return "kugou"
	case h == "lrclib.net" || strings.HasSuffix(h, ".lrclib.net"):
		return "lrclib"
	case h == "musixmatch.com" || strings.HasSuffix(h, ".musixmatch.com"):
		return "musixmatch"
	case h == "raw.githubusercontent.com":
		return "amll"
	case h == "music.youtube.com":
		return "lyricfind"
	case h == "kuwo.cn" || strings.HasSuffix(h, ".kuwo.cn"):
		return "kuwo"
	case h == "migu.cn" || strings.HasSuffix(h, ".migu.cn"):
		return "migu"
	case h == "deezer.com" || strings.HasSuffix(h, ".deezer.com"):
		return "deezer"
	}
	return ""
}

func (b *lyricSourceBreaker) observe(host string, err error, status int, retryAfter string) {
	b.observeWith(host, err, status, retryAfter, transportTrace{})
}

func (b *lyricSourceBreaker) observeWith(host string, err error, status int, retryAfter string, tr transportTrace) {
	source := lyricSourceForHost(host)
	if source == "" {
		return
	}

	if err != nil && errors.Is(err, context.Canceled) {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.noteTransport(source, err, status, tr)
	now := b.now()
	st := b.state[source]
	switch {
	case err != nil || status >= 500:
		reason := lyricSourceCooldownReasonNetwork
		if err == nil {
			reason = lyricSourceCooldownReasonServerError
		}
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		st.consecutive++
		if st.consecutive < lyricSourceBreakerTripAfter {
			return
		}

		if st.until.After(now) {
			return
		}
		idx := st.trips
		if idx >= len(lyricSourceBreakerSchedule) {
			idx = len(lyricSourceBreakerSchedule) - 1
		}
		st.trips++
		st.until = now.Add(lyricSourceBreakerSchedule[idx])
		st.reason = reason
		log.Printf("lyrics: source %s cooling down %s (reason=%s trip=%d consecutive=%d host=%s)",
			source, lyricSourceBreakerSchedule[idx], reason, st.trips, st.consecutive, host)
	case status == http.StatusTooManyRequests:
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		d := parseLyricSourceRetryAfter(retryAfter)
		st.until = now.Add(d)
		st.reason = lyricSourceCooldownReasonRateLimited
		log.Printf("lyrics: source %s cooling down %s (reason=%s host=%s)", source, d, st.reason, host)
	default:
		if st == nil {
			return
		}
		if st.until.After(now) {
			log.Printf("lyrics: source %s recovered, cooldown cleared (reason=%s)", source, st.reason)
		}
		delete(b.state, source)
	}
}

func parseLyricSourceRetryAfter(v string) time.Duration {
	secs, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || secs <= 0 {
		return lyricSourceBreakerRetryAfterDefault
	}
	d := time.Duration(secs) * time.Second
	if d > lyricSourceBreakerRetryAfterMax {
		d = lyricSourceBreakerRetryAfterMax
	}
	return d
}

type lyricSourceRoundPlan map[string]time.Duration

func (b *lyricSourceBreaker) planRound(sources []string, enabled func(string) bool) lyricSourceRoundPlan {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	plan := lyricSourceRoundPlan{}
	enabledTotal, enabledCooling := 0, 0
	for _, s := range sources {
		isEnabled := enabled(s)
		if isEnabled {
			enabledTotal++
		}
		if st := b.state[s]; st != nil && st.until.After(now) {
			plan[s] = st.until.Sub(now)
			if isEnabled {
				enabledCooling++
			}
		}
	}
	if len(plan) == 0 {
		return nil
	}
	if enabledTotal > 0 && enabledCooling == enabledTotal {
		log.Printf("lyrics: all %d enabled sources are cooling down, running the round anyway", enabledTotal)
		return nil
	}
	return plan
}

var anyLyricSourceCooling = func(sources []string) bool {
	for _, s := range sources {
		if _, cooling := lyricSourceBreakerShared.coolingDown(s); cooling {
			return true
		}
	}
	return false
}

func (b *lyricSourceBreaker) coolingDown(source string) (time.Duration, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	st := b.state[source]
	if st == nil || !st.until.After(b.now()) {
		return 0, false
	}
	return st.until.Sub(b.now()), true
}

type lyricSourceRound struct {
	mu      sync.Mutex
	skipped map[string]bool
	failed  map[string]bool
}

type lyricSourceRoundKey struct{}

func withLyricSourceRound(ctx context.Context) (context.Context, *lyricSourceRound) {
	r := &lyricSourceRound{skipped: map[string]bool{}, failed: map[string]bool{}}
	return context.WithValue(ctx, lyricSourceRoundKey{}, r), r
}

func lyricSourceRoundFrom(ctx context.Context) *lyricSourceRound {
	if ctx == nil {
		return nil
	}
	r, _ := ctx.Value(lyricSourceRoundKey{}).(*lyricSourceRound)
	return r
}

type lyricSourceOnlyKey struct{}

func withLyricSourceOnly(ctx context.Context, sources []string) context.Context {
	if len(sources) == 0 {
		return ctx
	}
	set := make(map[string]bool, len(sources))
	for _, s := range sources {
		set[s] = true
	}
	return context.WithValue(ctx, lyricSourceOnlyKey{}, set)
}

func lyricSourceOnlyFrom(ctx context.Context) map[string]bool {
	if ctx == nil {
		return nil
	}
	set, _ := ctx.Value(lyricSourceOnlyKey{}).(map[string]bool)
	return set
}

func (r *lyricSourceRound) markSkipped(source string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.skipped[source] = true
	r.mu.Unlock()
}

func (r *lyricSourceRound) markFailed(source string) {
	if r == nil || source == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failed == nil {
		r.failed = map[string]bool{}
	}
	r.failed[source] = true
}

func (r *lyricSourceRound) failedSources() []string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	var result []string
	for source := range r.failed {
		result = append(result, source)
	}
	sort.Strings(result)
	return result
}

func noteLyricRoundFailure(ctx context.Context, host string, err error, status int) {
	if errors.Is(err, context.Canceled) {
		return
	}
	if err != nil || status >= 500 || status == http.StatusTooManyRequests {
		lyricSourceRoundFrom(ctx).markFailed(lyricSourceForHost(host))
	}
}

func (r *lyricSourceRound) skippedSources() []string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.skipped) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.skipped))
	for s := range r.skipped {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

type lyricSourceTransportState struct {
	responded bool
	failures  map[string]int
}

type transportTrace struct {
	dnsStarted bool
	dnsDone    bool
	dnsErr     error
}

func classifyLyricSourceTransportFailure(err error, status int, tr transportTrace) string {
	if err == nil {
		if status >= 500 {
			return lyricFailureReasonServerError
		}
		return ""
	}

	if tr.dnsStarted && (!tr.dnsDone || tr.dnsErr != nil) {
		return lyricFailureReasonDNSFailed
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return lyricFailureReasonDNSFailed
	}
	return lyricFailureReasonConnectFailed
}

func (b *lyricSourceBreaker) observeTraced(host string, err error, status int, retryAfter string, tr transportTrace) {
	b.observeWith(host, err, status, retryAfter, tr)
}

func (b *lyricSourceBreaker) noteTransport(source string, err error, status int, tr transportTrace) {
	ts := b.transport[source]
	if ts == nil {
		ts = &lyricSourceTransportState{failures: map[string]int{}}
		b.transport[source] = ts
	}
	code := classifyLyricSourceTransportFailure(err, status, tr)
	if code == "" {
		ts.responded = true
		return
	}
	ts.failures[code]++
}

var lyricSourceTransportFailureOrder = []string{
	lyricFailureReasonDNSFailed, lyricFailureReasonConnectFailed, lyricFailureReasonServerError,
}

func dominantLyricSourceTransportFailure(failures map[string]int) string {
	best, bestN := "", 0
	for _, code := range lyricSourceTransportFailureOrder {
		if n := failures[code]; n > bestN {
			best, bestN = code, n
		}
	}
	return best
}

func (b *lyricSourceBreaker) transportFailureCodes() map[string]string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]string{}
	for source, ts := range b.transport {
		if ts.responded || len(ts.failures) == 0 {
			continue
		}
		if code := dominantLyricSourceTransportFailure(ts.failures); code != "" {
			out[source] = code
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
