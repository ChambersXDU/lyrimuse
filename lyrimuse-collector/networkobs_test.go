package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func attemptDelta(before int32) int32 { return atomic.LoadInt32(&networkAttemptCount) - before }
func failureDelta(before int32) int32 { return atomic.LoadInt32(&networkFailureCount) - before }

func TestDoHTTPTracked_SuccessfulResponseNotCountedAsFailure(t *testing.T) {

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	attemptsBefore := atomic.LoadInt32(&networkAttemptCount)
	failuresBefore := atomic.LoadInt32(&networkFailureCount)

	req, err := http.NewRequest(http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err != nil {
		t.Fatalf("expected no transport error, got: %v", err)
	}
	resp.Body.Close()

	if got := attemptDelta(attemptsBefore); got != 1 {
		t.Fatalf("expected exactly 1 new attempt recorded, got %d", got)
	}
	if got := failureDelta(failuresBefore); got != 0 {
		t.Fatalf("a successful (even non-200) response must not count as a network failure, got %d new failures", got)
	}
}

func TestDoHTTPTracked_TransportErrorCountsAsFailure(t *testing.T) {

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	attemptsBefore := atomic.LoadInt32(&networkAttemptCount)
	failuresBefore := atomic.LoadInt32(&networkFailureCount)

	req, err := http.NewRequest(http.MethodGet, "http://"+addr, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	_, err = doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err == nil {
		t.Fatalf("expected a transport-level error connecting to a closed port")
	}

	if got := attemptDelta(attemptsBefore); got != 1 {
		t.Fatalf("expected exactly 1 new attempt recorded, got %d", got)
	}
	if got := failureDelta(failuresBefore); got != 1 {
		t.Fatalf("expected exactly 1 new failure recorded, got %d", got)
	}
}

func TestDoHTTPTracked_LogsSuccessWithoutQueryString(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	defer slog.SetLogLoggerLevel(slog.SetLogLoggerLevel(slog.LevelDebug))

	req, err := http.NewRequest(http.MethodGet, srv.URL+"/2.0/?method=track.getinfo&api_key=SECRET1234567890", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err != nil {
		t.Fatalf("expected no transport error, got: %v", err)
	}
	resp.Body.Close()

	logged := buf.String()
	if !strings.Contains(logged, "200") {
		t.Fatalf("expected the status code to appear in the log line, got: %q", logged)
	}
	if !strings.Contains(logged, "method=track.getinfo") {
		t.Fatalf("expected the safe 'method' query param to be surfaced, got: %q", logged)
	}
	if strings.Contains(logged, "SECRET1234567890") || strings.Contains(logged, "api_key") {
		t.Fatalf("api_key must never appear in the audit log line, got: %q", logged)
	}
}

func TestDoHTTPTracked_LogsFailure(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	req, err := http.NewRequest(http.MethodGet, "http://"+addr+"/submit-listens?token=SECRETTOKEN1234", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	_, err = doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err == nil {
		t.Fatalf("expected a transport-level error connecting to a closed port")
	}

	logged := buf.String()
	if !strings.Contains(logged, "FAILED") {
		t.Fatalf("expected the failure path to be logged as FAILED, got: %q", logged)
	}
	if strings.Contains(logged, "SECRETTOKEN1234") {
		t.Fatalf("token must never appear in the audit log line, got: %q", logged)
	}
}

func TestNetworkLooksDown_RequiresMinimumAttemptsAndAllFailed(t *testing.T) {

	reset := func(attempts, failures int32) {
		atomic.StoreInt32(&networkAttemptCount, attempts)
		atomic.StoreInt32(&networkFailureCount, failures)
	}
	defer reset(atomic.LoadInt32(&networkAttemptCount), atomic.LoadInt32(&networkFailureCount))

	reset(0, 0)
	if networkLooksDown() {
		t.Fatalf("zero attempts must never be judged as network-down")
	}

	reset(2, 2)
	if networkLooksDown() {
		t.Fatalf("too few attempts (2) even if all failed must not be judged as network-down — avoids misjudging \"this song has little metadata so few requests were made\" as \"network is down\"")
	}

	reset(5, 3)
	if networkLooksDown() {
		t.Fatalf("some requests succeeded — must not be judged as network-down")
	}

	reset(5, 5)
	if !networkLooksDown() {
		t.Fatalf("enough attempts, all failed — must be judged as network-down")
	}
}

func TestAPICallSummary_AggregatesPerTargetPerMinute(t *testing.T) {
	apiCallAgg.mu.Lock()
	apiCallAgg.windows = map[string]*apiCallWindow{}
	apiCallAgg.mu.Unlock()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	t0 := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	recordAPICall("GET example.com/a", 100*time.Millisecond, false, t0)
	recordAPICall("GET example.com/a", 300*time.Millisecond, false, t0.Add(20*time.Second))
	recordAPICall("GET example.com/a", 900*time.Millisecond, true, t0.Add(40*time.Second))
	recordAPICall("POST example.com/b", 50*time.Millisecond, false, t0.Add(10*time.Second))

	flushAPICallSummaries(t0.Add(30*time.Second), false)
	if buf.Len() != 0 {
		t.Fatalf("window not yet a minute old must not be summarized, got: %q", buf.String())
	}
	flushAPICallSummaries(t0.Add(61*time.Second), false)
	out := buf.String()
	for _, want := range []string{
		`target="GET example.com/a"`, "count=3", "failed=1", "p50_ms=300", "max_ms=900", "span_s=40",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("summary line missing %s, got: %q", want, out)
		}
	}
	if strings.Contains(out, "example.com/b") {
		t.Fatalf("target b opened at +10s must not be summarized at +61s, got: %q", out)
	}
	buf.Reset()
	flushAPICallSummaries(t0.Add(61*time.Second), true)
	if !strings.Contains(buf.String(), `target="POST example.com/b"`) || !strings.Contains(buf.String(), "count=1") {
		t.Fatalf("force flush must summarize the remaining window, got: %q", buf.String())
	}
	buf.Reset()
	flushAPICallSummaries(t0.Add(time.Hour), true)
	if buf.Len() != 0 {
		t.Fatalf("summarized windows must be cleared, got: %q", buf.String())
	}
}

func TestNormalizeAuditPath(t *testing.T) {
	cases := map[string]string{
		"/artwork/f8863d3086cd50bf.jpg":                     "/artwork/<hex>.jpg",
		"/ws/2/artist/4c8ead39-b9df-4c56-a27c-51bc049cfd48": "/ws/2/artist/<uuid>",
		"/2.0/":                                "/2.0/",
		"/v8/fcg-bin/fcg_play_single_song.fcg": "/v8/fcg-bin/fcg_play_single_song.fcg",
		"/1/submit-listens":                    "/1/submit-listens",
		"/api/search/get":                      "/api/search/get",
		"/lyrics/1234567/lrc":                  "/lyrics/<n>/lrc",
		"/dl/ABCDEFGHIJKLMNOPQRSTUVWX0123456789/song.ttml": "/dl/<id>/song.ttml",
		"": "",
	}
	for in, want := range cases {
		if got := normalizeAuditPath(in); got != want {
			t.Fatalf("normalizeAuditPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDoHTTPTracked_HungDNSClassifiedAsDNSFailed(t *testing.T) {
	saved := lyricSourceBreakerShared
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() { lyricSourceBreakerShared = saved })

	hungResolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	cli := &http.Client{
		Timeout: 300 * time.Millisecond,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Resolver: hungResolver}).DialContext,
		},
	}
	req, _ := http.NewRequest(http.MethodGet, "http://music.163.com/api/search/get?s=x", nil)
	_, err := doHTTPTracked(cli, req)
	if err == nil {
		t.Fatal("挂住的解析器竟然成功了")
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		t.Logf("注意:这个 Go 版本的错误链里居然还带着 DNSError(%v),轨迹那条判据没被真正考到", err)
	}
	got := lyricSourceBreakerShared.transportFailureCodes()
	if got["netease"] != lyricFailureReasonDNSFailed {
		t.Fatalf("netease 应为 dns_failed,实际 %q(err=%v)", got["netease"], err)
	}
}

func TestDoHTTPTracked_RefusedConnectionClassifiedAsConnectFailed(t *testing.T) {
	saved := lyricSourceBreakerShared
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() { lyricSourceBreakerShared = saved })

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	localResolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return nil, errors.New("unused")
		},
	}
	dialer := &net.Dialer{Resolver: localResolver}
	cli := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {

				return dialer.DialContext(ctx, network, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
			},
		},
	}
	req, _ := http.NewRequest(http.MethodGet, "http://c.y.qq.com/soso/x", nil)
	if _, err := doHTTPTracked(cli, req); err == nil {
		t.Fatal("连到已关闭端口竟然成功了")
	}
	got := lyricSourceBreakerShared.transportFailureCodes()
	if got["qq"] != lyricFailureReasonConnectFailed {
		t.Fatalf("qq 应为 connect_failed,实际 %q", got["qq"])
	}
}
