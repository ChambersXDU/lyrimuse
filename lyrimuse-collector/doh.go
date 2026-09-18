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

// DoH (DNS over HTTPS) resolution for domains prone to local DNS poisoning or misdirection.
//
// Certain service endpoints (such as apic-appmobile.musixmatch.com and apic-desktop.musixmatch.com)
// may resolve to invalid IP ranges on specific ISP or local DNS resolvers, causing TLS handshake
// failures ("no alternative certificate subject name matches target host name").
//
// By querying trusted DoH resolvers (Cloudflare 1.1.1.1 and Google 8.8.8.8) directly via IP,
// authentic host addresses are resolved, bypassing poisoned local DNS caches.
//
// Fallback sequence:
//   - Musixmatch uses DoH-first resolution because local DNS frequently returns incorrect IPs.
//   - General lyric sources (lyricsourcedial.go) use system-DNS-first resolution, querying DoH
//     only when system DNS fails to resolve.
//   - If DoH resolution fails, calls fall back gracefully to system DNS.
const (
	dohTimeout  = 4 * time.Second
	dohCacheTTL = 30 * time.Minute
	// 单个地址的拨号上限。有了 dohDialRace 的并发拨号之后,这个值不再决定"整体等多久"
	// (黑洞地址不会再挡住好地址),真正卡总时长的是调用方 ctx 上的 deadline
	// —— dohHTTPClient 那条路上是 proxyFallbackTransport 的 3s 直连预算。
	dohDialTimeout         = 8 * time.Second
	dohTLSHandshakeTimeout = 8 * time.Second
)

// 两个 DoH 端点都用 IP 直连(自己不需要再解析一次 DNS,否则就是鸡生蛋)。
// 按顺序试,先成功先用。
var dohEndpoints = []string{
	"https://1.1.1.1/dns-query",
	"https://8.8.8.8/resolve",
}

// 需要绕过系统 DNS 的域名后缀。故意用一份显式清单而不是"全都走 DoH":
// 把整个进程的解析行为改掉,影响面远超这个 bug 需要修的范围。
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

// dohLookup 返回这个域名的 A 记录。查不到/查询失败返回 nil,调用方据此退回系统解析。
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
	// 失败也缓存(空结果),避免每次请求都为一个解析不出来的域名重试一遍 DoH。
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
	// 这里**不能**用 doHTTPTracked:DoH 查询的成败跟"歌词源可不可达"是两回事,记进
	// networkLooksDown 的统计里会污染那个判断(见 networkobs.go)。
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

// dohParseAnswer 从 DoH 的 JSON 响应里挑出 A 记录(type==1)的地址。
// 单独拆出来是为了能用固定样本做单测,不需要真的联网。
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
		if a.Type != 1 { // 1 = A 记录；CNAME(5) 之类跳过
			continue
		}
		if ip := net.ParseIP(a.Data); ip != nil && ip.To4() != nil {
			ips = append(ips, a.Data)
		}
	}
	return ips
}

// dohDialContext 是给 http.Transport 用的拨号器:命中清单里的域名就连 DoH 解析出的
// 地址,其余一律走系统解析。
//
// 只改拨号的目标地址,**不碰 TLS** —— crypto/tls 用的 ServerName 来自 URL 里的域名,
// 不是这里的 IP,所以证书照常按域名严格校验(跟 curl --resolve 是同一个机制)。绝不能
// 为了"连得上"去关 InsecureSkipVerify:那才是真的把连接置于风险之中。
func dohDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || !dohShouldResolve(host) {
		return dohDialer().DialContext(ctx, network, addr)
	}
	conn, raceErr := dohDialRace(ctx, network, dohLookup(host), port)
	if conn != nil {
		return conn, nil
	}
	// DoH 没结果、或者拿到的地址都连不上:退回系统解析,行为跟没有这套东西时一致。
	conn, err = dohDialer().DialContext(ctx, network, addr)
	if err != nil && raceErr != nil {
		return nil, fmt.Errorf("%w (DoH 地址也连不上: %v)", err, raceErr)
	}
	return conn, err
}

func dohDialer() *net.Dialer {
	return &net.Dialer{Timeout: dohDialTimeout, KeepAlive: 30 * time.Second}
}

// dohDialRace dials each IP address resolved by DoH concurrently, returning the first
// successful connection and closing any subsequent slower connections. If ips is empty,
// returns (nil, nil) allowing caller fallback to system resolution.
//
// Concurrent dialing follows the Happy Eyeballs pattern across multiple addresses:
// if one resolved IP is unresponsive (blackhole), other healthy IPs race to connect
// without waiting for serial timeout budgets.
func dohDialRace(ctx context.Context, network string, ips []string, port string) (net.Conn, error) {
	return dohDialRaceWith(ctx, dohDialer().DialContext, network, ips, port)
}

// dohDialRaceWith 是 dohDialRace 的可注入版本。拆出来只为单测:要证明"第一个地址是黑洞
// 时不再挡住第二个",就得有一个**真的永远不返回**的拨号目标,而真实网络里没有可移植、
// 可复现的黑洞地址(RFC 5737 那几段在不同网络下有时秒回 EHOSTUNREACH、有时超时)。
// 生产路径只有 dohDialRace 一个调用方,传的永远是真拨号器。
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
	// 缓冲开满:输家写进来永远不会阻塞,即使赢家已经把结果交出去、没人再读。
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
			// 有人连上了:立刻交出去,**不等**剩下那几个 —— 等它们就等于没有并发,黑洞
			// 那条要到 dialer.Timeout 才返回。cancel 让它们尽快收工,收尾 goroutine 把
			// 万一也连上的连接关掉,不泄漏 fd。
			//
			// cancel 不会影响已经交出去的这条:net.Dialer 的 ctx 只管拨号过程,连接建成
			// 之后 ctx 过期/取消对它没有作用(标准库文档明写)。
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

// dohHTTPClient constructs an http.Client with direct DoH connection precedence and
// automatic fallback to system proxy (proxyFallbackTransport).
//
// onBlocked is invoked when direct attempts fail and proxy fallback cannot recover,
// recording specific failure rationale. Can be nil.
//
// Note: http.Client.Timeout is intentionally unset to prevent direct and proxy attempts
// from competing for the same timeout budget; timeouts are enforced per-attempt inside
// proxyFallbackTransport (3s direct / 10s proxy) and bounded by the caller's context deadline.
func dohHTTPClient(onBlocked func()) *http.Client {
	return &http.Client{
		Transport: &proxyFallbackTransport{
			direct: &http.Transport{
				DialContext:         dohDialContext,
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},
			// 走代理时拨的是代理自己的地址(通常是 127.0.0.1),DoH 对它没有意义,用默认
			// 拨号器即可;目标域名交给代理去解析。
			viaProxy: &http.Transport{
				Proxy:               func(*http.Request) (*neturl.URL, error) { return systemProxyURL(), nil },
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},
			onBlocked: onBlocked,
		},
	}
}
