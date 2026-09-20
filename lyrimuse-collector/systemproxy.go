package main

import (
	"context"
	"log"
	"net"
	neturl "net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (

	systemProxyCacheTTL = 60 * time.Second

	systemProxyReadTimeout = 2 * time.Second

	systemProxyProbeTimeout = 400 * time.Millisecond
)

var (
	systemProxyMu     sync.Mutex
	systemProxyValue  *neturl.URL
	systemProxyReadAt time.Time
)

func systemProxyURL() *neturl.URL {
	systemProxyMu.Lock()
	defer systemProxyMu.Unlock()
	if !systemProxyReadAt.IsZero() && time.Since(systemProxyReadAt) < systemProxyCacheTTL {
		return systemProxyValue
	}
	u := readSystemProxyURL()
	if u != nil && !proxyReachable(u) {
		log.Printf("proxy: system proxy %s is configured but unreachable, treating this round as no proxy", u.Host)
		u = nil
	}
	systemProxyValue, systemProxyReadAt = u, time.Now()
	return u
}

func readSystemProxyURL() *neturl.URL {
	if u := envProxyURL(); u != nil {
		return u
	}
	ctx, cancel := context.WithTimeout(context.Background(), systemProxyReadTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		return nil
	}
	return parseSCUtilProxy(string(out))
}

func envProxyURL() *neturl.URL {

	for _, key := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"} {
		v := strings.TrimSpace(os.Getenv(key))
		if v == "" {
			continue
		}
		if !strings.Contains(v, "://") {
			v = "http://" + v
		}
		if u, err := neturl.Parse(v); err == nil && u.Host != "" {
			return u
		}
	}
	return nil
}

func parseSCUtilProxy(out string) *neturl.URL {
	kv := map[string]string{}

	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(line, " : ")
		if !ok {
			continue
		}
		kv[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	for _, c := range []struct{ enable, host, port, scheme string }{
		{"HTTPSEnable", "HTTPSProxy", "HTTPSPort", "http"},
		{"HTTPEnable", "HTTPProxy", "HTTPPort", "http"},
		{"SOCKSEnable", "SOCKSProxy", "SOCKSPort", "socks5"},
	} {
		if kv[c.enable] != "1" {
			continue
		}
		host, port := kv[c.host], kv[c.port]
		if host == "" || port == "" {
			continue
		}
		if n, err := strconv.Atoi(port); err != nil || n <= 0 || n > 65535 {
			continue
		}
		return &neturl.URL{Scheme: c.scheme, Host: net.JoinHostPort(host, port)}
	}
	return nil
}

func proxyReachable(u *neturl.URL) bool {
	conn, err := net.DialTimeout("tcp", u.Host, systemProxyProbeTimeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
