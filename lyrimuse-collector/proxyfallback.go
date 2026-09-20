package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (

	proxyFallbackDirectBudget = 3 * time.Second

	proxyFallbackProxyBudget = 10 * time.Second

	proxyFallbackSticky = 10 * time.Minute
)

type proxyFallbackTransport struct {
	direct   http.RoundTripper
	viaProxy http.RoundTripper

	onBlocked func()

	mu          sync.Mutex
	stickyUntil time.Time
}

func (t *proxyFallbackTransport) RoundTrip(req *http.Request) (*http.Response, error) {

	if req.Body != nil {
		return t.attempt(t.direct, req, proxyFallbackDirectBudget)
	}

	host := req.URL.Hostname()

	if t.preferProxy(host) {
		resp, err := t.attempt(t.viaProxy, req, proxyFallbackProxyBudget)
		if err == nil {
			return resp, nil
		}

		t.clearSticky(host)
		log.Printf("proxy: %s failed via proxy (%v), clearing sticky proxy and retrying direct", host, err)
		resp, err = t.attempt(t.direct, req, proxyFallbackDirectBudget)
		if err != nil {
			t.reportBlocked()
		}
		return resp, err
	}

	directStart := time.Now()
	resp, directErr := t.attempt(t.direct, req, proxyFallbackDirectBudget)
	directElapsed := time.Since(directStart)
	if directErr == nil {
		return resp, nil
	}
	proxy := systemProxyURL()
	if proxy == nil {
		t.reportBlocked()
		return nil, directErr
	}
	proxyStart := time.Now()
	resp, proxyErr := t.attempt(t.viaProxy, req, proxyFallbackProxyBudget)
	if proxyErr != nil {
		t.reportBlocked()

		log.Printf("proxy: %s direct failed (%v, %s), then failed via system proxy %s too (%v, %s)",
			host, directErr, directElapsed.Round(time.Millisecond),
			proxy.Host, proxyErr, time.Since(proxyStart).Round(time.Millisecond))
		return nil, directErr
	}
	t.markSticky(host)
	log.Printf("proxy: %s direct failed (%v, %s), succeeded via system proxy %s (%s), using the proxy for the next %s",
		host, directErr, directElapsed.Round(time.Millisecond), proxy.Host,
		time.Since(proxyStart).Round(time.Millisecond), proxyFallbackSticky)
	return resp, nil
}

func (t *proxyFallbackTransport) attempt(rt http.RoundTripper, req *http.Request, budget time.Duration) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(req.Context(), budget)
	resp, err := rt.RoundTrip(req.Clone(ctx))
	if err != nil {
		cancel()
		return nil, err
	}

	resp.Body = &proxyFallbackBody{ReadCloser: resp.Body, cancel: cancel}
	return resp, nil
}

type proxyFallbackBody struct {
	io.ReadCloser
	cancel context.CancelFunc
	once   sync.Once
}

func (b *proxyFallbackBody) Close() error {
	err := b.ReadCloser.Close()
	b.once.Do(b.cancel)
	return err
}

func (t *proxyFallbackTransport) reportBlocked() {
	if t.onBlocked != nil {
		t.onBlocked()
	}
}

func (t *proxyFallbackTransport) preferProxy(host string) bool {
	t.mu.Lock()
	sticky := time.Now().Before(t.stickyUntil)
	t.mu.Unlock()
	if !sticky && !loadProxyFallbackHint(host) {
		return false
	}
	return systemProxyURL() != nil
}

func (t *proxyFallbackTransport) markSticky(host string) {
	t.mu.Lock()
	t.stickyUntil = time.Now().Add(proxyFallbackSticky)
	t.mu.Unlock()
	saveProxyFallbackHint(host, true)
}

func (t *proxyFallbackTransport) clearSticky(host string) {
	t.mu.Lock()
	t.stickyUntil = time.Time{}
	t.mu.Unlock()
	saveProxyFallbackHint(host, false)
}

type proxyFallbackHintFile struct {

	Hosts map[string]int64 `json:"hosts"`
}

func proxyFallbackHintPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-proxy-hint.json")
}

func readProxyFallbackHint() proxyFallbackHintFile {
	f := proxyFallbackHintFile{Hosts: map[string]int64{}}
	path := proxyFallbackHintPath()
	if path == "" {
		return f
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return f
	}
	var parsed proxyFallbackHintFile
	if json.Unmarshal(raw, &parsed) != nil || parsed.Hosts == nil {
		return f
	}
	return parsed
}

func loadProxyFallbackHint(host string) bool {
	at, ok := readProxyFallbackHint().Hosts[host]
	if !ok {
		return false
	}
	return time.Since(time.Unix(at, 0)) < proxyFallbackSticky
}

func saveProxyFallbackHint(host string, useProxy bool) {
	path := proxyFallbackHintPath()
	if path == "" {
		return
	}
	f := readProxyFallbackHint()
	if useProxy {
		f.Hosts[host] = time.Now().Unix()
	} else {
		delete(f.Hosts, host)
	}
	raw, err := json.Marshal(f)
	if err != nil {
		return
	}

	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
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
