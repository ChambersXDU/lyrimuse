package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

const (
	dohTimeout  = 4 * time.Second
	dohCacheTTL = 30 * time.Minute

	dohDialTimeout         = 8 * time.Second
	dohTLSHandshakeTimeout = 8 * time.Second
)

var dohEndpoints = []string{
	"https://1.1.1.1/dns-query",
	"https://8.8.8.8/resolve",
}

var dohHostSuffixes = []string{
	".musixmatch.com",
}

type dohEntry struct {
	ips     []string
	expires time.Time
}

var (
	dohMu    sync.Mutex
	dohCache = map[string]dohEntry{}
)

func dohShouldResolve(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	for _, suffix := range dohHostSuffixes {
		if strings.HasSuffix(h, suffix) {
			return true
		}
	}
	return false
}

func dohLookup(host string) []string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))

	dohMu.Lock()
	if e, ok := dohCache[host]; ok && time.Now().Before(e.expires) {
		ips := e.ips
		dohMu.Unlock()
		return ips
	}
	dohMu.Unlock()

	var ips []string
	for _, endpoint := range dohEndpoints {
		if got := dohQuery(endpoint, host); len(got) > 0 {
			ips = got
			break
		}
	}

	dohMu.Lock()
	dohCache[host] = dohEntry{ips: ips, expires: time.Now().Add(dohCacheTTL)}
	dohMu.Unlock()
	return ips
}

var dohQueryHTTPClient = &http.Client{Timeout: dohTimeout}

func dohQuery(endpoint, host string) []string {
	url := fmt.Sprintf("%s?name=%s&type=A", endpoint, host)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Accept", "application/dns-json")

	resp, err := dohQueryHTTPClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return nil
	}
	return dohParseAnswer(body)
}

func dohParseAnswer(body []byte) []string {
	var out struct {
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if json.Unmarshal(body, &out) != nil {
		return nil
	}
	var ips []string
	for _, a := range out.Answer {
		if a.Type != 1 {
			continue
		}
		if ip := net.ParseIP(a.Data); ip != nil && ip.To4() != nil {
			ips = append(ips, a.Data)
		}
	}
	return ips
}

func dohDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || !dohShouldResolve(host) {
		return dohDialer().DialContext(ctx, network, addr)
	}
	conn, raceErr := dohDialRace(ctx, network, dohLookup(host), port)
	if conn != nil {
		return conn, nil
	}

	conn, err = dohDialer().DialContext(ctx, network, addr)
	if err != nil && raceErr != nil {
		return nil, fmt.Errorf("%w (DoH 地址也连不上: %v)", err, raceErr)
	}
	return conn, err
}

func dohDialer() *net.Dialer {
	return &net.Dialer{Timeout: dohDialTimeout, KeepAlive: 30 * time.Second}
}

func dohDialRace(ctx context.Context, network string, ips []string, port string) (net.Conn, error) {
	return dohDialRaceWith(ctx, dohDialer().DialContext, network, ips, port)
}

func dohDialRaceWith(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error),
	network string, ips []string, port string) (net.Conn, error) {
	if len(ips) == 0 {
		return nil, nil
	}
	dialCtx, cancel := context.WithCancel(ctx)
	type dialOutcome struct {
		conn net.Conn
		err  error
	}

	ch := make(chan dialOutcome, len(ips))
	for _, ip := range ips {
		go func(ip string) {
			conn, err := dial(dialCtx, network, net.JoinHostPort(ip, port))
			ch <- dialOutcome{conn, err}
		}(ip)
	}
	var firstErr error
	for remaining := len(ips); remaining > 0; remaining-- {
		select {
		case out := <-ch:
			if out.err != nil {
				if firstErr == nil {
					firstErr = out.err
				}
				continue
			}

			go func(n int) {
				defer cancel()
				for i := 0; i < n; i++ {
					if o := <-ch; o.conn != nil {
						_ = o.conn.Close()
					}
				}
			}(remaining - 1)
			return out.conn, nil
		case <-dialCtx.Done():
			cancel()
			return nil, dialCtx.Err()
		}
	}
	cancel()
	return nil, firstErr
}

func dohHTTPClient(onBlocked func()) *http.Client {
	return &http.Client{
		Transport: &proxyFallbackTransport{
			direct: &http.Transport{
				DialContext:         dohDialContext,
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},

			viaProxy: &http.Transport{
				Proxy:               func(*http.Request) (*neturl.URL, error) { return systemProxyURL(), nil },
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},
			onBlocked: onBlocked,
		},
	}
}
