package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httptrace"
	"sync"
	"time"
)

const (
	lyricSourceSystemDNSBudget  = 2 * time.Second
	lyricSourceSystemDNSFailTTL = 60 * time.Second
)

var (
	lyricSourceSystemLookup = func(ctx context.Context, host string) ([]net.IPAddr, error) {
		return net.DefaultResolver.LookupIPAddr(ctx, host)
	}
	lyricSourceDoHLookup = dohLookup
	lyricSourceDial      = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dohDialer().DialContext(ctx, network, addr)
	}
)

var lyricSourceTransport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DialContext = lyricSourceDialContext
	return t
}()

var (
	lyricHTTPClientsMu sync.RWMutex
	lyricHTTPClients   = map[time.Duration]*http.Client{}
)

func lyricHTTPClient(timeout time.Duration) *http.Client {
	lyricHTTPClientsMu.RLock()
	c, ok := lyricHTTPClients[timeout]
	lyricHTTPClientsMu.RUnlock()
	if ok {
		return c
	}
	lyricHTTPClientsMu.Lock()
	defer lyricHTTPClientsMu.Unlock()
	if c, ok := lyricHTTPClients[timeout]; ok {
		return c
	}
	c = &http.Client{Timeout: timeout, Transport: lyricSourceTransport}
	lyricHTTPClients[timeout] = c
	return c
}

var (
	lyricSourceSystemDNSFailMu    sync.Mutex
	lyricSourceSystemDNSFailUntil = map[string]time.Time{}

	lyricSourceSystemDNSLogAt = map[string]time.Time{}
)

const lyricSourceSystemDNSLogEvery = 10 * time.Minute

func lyricSourceSystemDNSRecentlyFailed(host string, now time.Time) bool {
	lyricSourceSystemDNSFailMu.Lock()
	defer lyricSourceSystemDNSFailMu.Unlock()
	return lyricSourceSystemDNSFailUntil[host].After(now)
}

func markLyricSourceSystemDNSFailed(host string, now time.Time) (shouldLog bool) {
	lyricSourceSystemDNSFailMu.Lock()
	defer lyricSourceSystemDNSFailMu.Unlock()
	lyricSourceSystemDNSFailUntil[host] = now.Add(lyricSourceSystemDNSFailTTL)
	if now.Sub(lyricSourceSystemDNSLogAt[host]) < lyricSourceSystemDNSLogEvery {
		return false
	}
	lyricSourceSystemDNSLogAt[host] = now
	return true
}

func lyricSourceDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || net.ParseIP(host) != nil {

		return lyricSourceDial(ctx, network, addr)
	}
	trace := httptrace.ContextClientTrace(ctx)
	now := time.Now()
	var sysErr error
	if !lyricSourceSystemDNSRecentlyFailed(host, now) {
		lookupCtx, cancel := context.WithTimeout(ctx, lyricSourceSystemDNSBudget)
		addrs, lerr := lyricSourceSystemLookup(lookupCtx, host)
		cancel()
		if lerr == nil && len(addrs) > 0 {

			return lyricSourceDial(ctx, network, addr)
		}
		if lerr == nil {
			lerr = &net.DNSError{Err: "no addresses", Name: host, IsNotFound: true}
		}
		sysErr = lerr
		if markLyricSourceSystemDNSFailed(host, now) {
			log.Printf("dns: system resolver failed for %s (%v), falling back to DoH for %s", host, lerr, lyricSourceSystemDNSFailTTL)
		}
	} else {

		sysErr = &net.DNSError{Err: "system resolver failed recently, using DoH", Name: host}
		if trace != nil && trace.DNSStart != nil {
			trace.DNSStart(httptrace.DNSStartInfo{Host: host})
		}
	}

	ips := lyricSourceDoHLookup(host)
	if len(ips) == 0 {
		if trace != nil && trace.DNSDone != nil {
			trace.DNSDone(httptrace.DNSDoneInfo{Err: sysErr})
		}
		return nil, fmt.Errorf("%w (DoH 也没解析出地址)", sysErr)
	}
	if trace != nil && trace.DNSDone != nil {
		addrs := make([]net.IPAddr, 0, len(ips))
		for _, ip := range ips {
			if parsed := net.ParseIP(ip); parsed != nil {
				addrs = append(addrs, net.IPAddr{IP: parsed})
			}
		}
		trace.DNSDone(httptrace.DNSDoneInfo{Addrs: addrs})
	}
	conn, raceErr := dohDialRaceWith(ctx, lyricSourceDial, network, ips, port)
	if conn != nil {
		return conn, nil
	}
	if raceErr == nil {
		raceErr = errors.New("no address dialed")
	}

	return nil, fmt.Errorf("dial %s via DoH-resolved %v: %w", host, ips, raceErr)
}
