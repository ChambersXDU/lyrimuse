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

// ---- Lyric Source Dialing: System DNS First with DoH Fallback ----
//
// Dialing transport used by lyric sources (NetEase, QQ, Kugou, LRCLIB, Kuwo, Migu, AMLL, LyricFind).
// Resolves hostnames via system DNS first; falls back to DNS-over-HTTPS (DoH) only if system DNS
// fails (e.g. timeout, NXDOMAIN, or corporate VPN resolvers dropping music provider domains).
//
// Sequence rationale:
//   - Musixmatch (doh.go) uses DoH-first because local DNS may return poisoned IPs.
//   - General lyric sources use system-DNS-first to avoid unnecessary third-party DoH queries
//     under normal network conditions.
//
// Key design invariants:
//   - Dedicated system DNS budget (lyricSourceSystemDNSBudget = 2s): Prevents a hanging system DNS
//     resolver from exhausting the entire HTTP client timeout before DoH fallback can execute.
//   - Short-term negative cache (lyricSourceSystemDNSFailTTL = 60s): After a system DNS failure,
//     subsequent requests for that host within 60s immediately route to DoH, recovering automatically
//     once the negative cache expires.
//   - Synthetic httptrace reporting: Dispatches DNSStart and DNSDone trace hooks during DoH fallback
//     to ensure sourcebreaker transport-layer classification accurately distinguishes DNS failures
//     from TCP connection failures.
//   - Strict TLS validation: Dials resolved IP directly while preserving original host ServerName
//     for TLS SNI and certificate verification.


const (
	lyricSourceSystemDNSBudget  = 2 * time.Second
	lyricSourceSystemDNSFailTTL = 60 * time.Second
)

// 三个可注入点,只为单测(真实网络里没有可复现的"系统 DNS 不答"):生产路径永远是默认值。
var (
	lyricSourceSystemLookup = func(ctx context.Context, host string) ([]net.IPAddr, error) {
		return net.DefaultResolver.LookupIPAddr(ctx, host)
	}
	lyricSourceDoHLookup = dohLookup
	lyricSourceDial      = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dohDialer().DialContext(ctx, network, addr)
	}
)

// lyricSourceTransport 是八个歌词源(netease/qq/kugou/lrclib/kuwo/migu/amll/lyricfind)共用的
// Transport:DefaultTransport 的克隆(代理环境变量、连接池、HTTP/2 等一律照旧),只换拨号器。
var lyricSourceTransport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DialContext = lyricSourceDialContext
	return t
}()

var (
	lyricHTTPClientsMu sync.RWMutex
	lyricHTTPClients   = map[time.Duration]*http.Client{}
)

// lyricHTTPClient 是歌词源文件里造 client 的唯一入口(lyricsourcedial_test.go 用源码扫描钉着:
// 那八个文件里不许再出现裸的 `&http.Client{`)。复用共享的 *http.Client 实例,避免每次请求重复分配。
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
	// 上次为这个域名打过"退到 DoH"日志的时间:常驻 collector 在 VPN 下每 60 秒负缓存一过期就会
	// 重新失败一次,九个域名每分钟各一行是噪音,按域名 10 分钟最多记一行。
	lyricSourceSystemDNSLogAt = map[string]time.Time{}
)

const lyricSourceSystemDNSLogEvery = 10 * time.Minute

func lyricSourceSystemDNSRecentlyFailed(host string, now time.Time) bool {
	lyricSourceSystemDNSFailMu.Lock()
	defer lyricSourceSystemDNSFailMu.Unlock()
	return lyricSourceSystemDNSFailUntil[host].After(now)
}

// markLyricSourceSystemDNSFailed 记负缓存,返回这次要不要打日志(限频)。
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
		// 拆不开 / 本来就是 IP:没有解析这一步,原样交给标准拨号器。
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
			// 系统 DNS 正常:走标准拨号器(它会再解析一次,命中系统缓存,并对多地址做 Happy
			// Eyeballs)—— 这就是改动之前的路径,一个字节都不多。
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
		// 负缓存命中、跳过了系统解析:标准库没机会触发 DNSStart,自己补上,否则传输层分类看不到
		// "这次有解析阶段"。
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
	// 解析成功(靠 DoH)但地址连不上:这是连接层的失败,不再把系统解析那条错误包进来,
	// 免得传输层分类顺着错误链又认成 dns_failed(评审提过 dohDialContext 那处的同型问题)。
	return nil, fmt.Errorf("dial %s via DoH-resolved %v: %w", host, ips, raceErr)
}
