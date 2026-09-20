package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/url"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestBreaker() (*lyricSourceBreaker, *fakeClock) {
	clk := &fakeClock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
	return newLyricSourceBreaker(clk.now), clk
}

var errProbeDial = &net.OpError{Op: "dial", Err: errors.New("no such host")}

func TestLyricSourceForHost(t *testing.T) {
	cases := map[string]string{
		"music.163.com":                 "netease",
		"c.y.qq.com":                    "qq",
		"u.y.qq.com:443":                "qq",
		"KRCS.KUGOU.COM":                "kugou",
		"lyrics.kugou.com":              "kugou",
		"lrclib.net":                    "lrclib",
		"apic-appmobile.musixmatch.com": "musixmatch",
		"raw.githubusercontent.com":     "amll",
		"music.youtube.com":             "lyricfind",
		"search.kuwo.cn":                "kuwo",
		"pd.musicapp.migu.cn":           "migu",
		"d.musicapp.migu.cn":            "migu",
		"ws.audioscrobbler.com":         "",
		"api.listenbrainz.org":          "",
		"musicbrainz.org":               "",
		"itunes.apple.com":              "",
		"1.1.1.1":                       "",
		"notqq.com":                     "",
		"evil-163.com":                  "",
	}
	for host, want := range cases {
		if got := lyricSourceForHost(host); got != want {
			t.Errorf("lyricSourceForHost(%q) = %q, want %q", host, got, want)
		}
	}
}

func TestLyricSourceBreakerTripsAfterTwoFailuresAndEscalates(t *testing.T) {
	b, clk := newTestBreaker()
	b.observe("music.163.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("一次失败就熔断了——一次网络抖动不该让下一首歌少一个源")
	}
	b.observe("music.163.com", errProbeDial, 0, "")
	if d, cooling := b.coolingDown("netease"); !cooling || d != 15*time.Second {
		t.Fatalf("两次失败后应冷却 15s,实际 cooling=%v d=%s", cooling, d)
	}
	clk.advance(15 * time.Second)
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("15s 到期后应放行")
	}

	b.observe("music.163.com", nil, 502, "")
	if d, _ := b.coolingDown("netease"); d != 30*time.Second {
		t.Fatalf("第三次失败应升到 30s,实际 %s", d)
	}
	for _, want := range []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 5 * time.Minute} {
		d, _ := b.coolingDown("netease")
		clk.advance(d)
		b.observe("music.163.com", errProbeDial, 0, "")
		if got, _ := b.coolingDown("netease"); got != want {
			t.Fatalf("冷却到期后再失败应升到 %s,实际 %s", want, got)
		}
	}

	b.observe("music.163.com", nil, 200, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("成功后应立即清除冷却")
	}

	b.observe("music.163.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("netease"); cooling {
		t.Fatal("成功清零后单次失败不应熔断")
	}
}

func TestLyricSourceBreakerDoesNotEscalateWithinOneCooldown(t *testing.T) {
	b, clk := newTestBreaker()

	for i := 0; i < 20; i++ {
		b.observe("c.y.qq.com", errProbeDial, 0, "")
		clk.advance(2 * time.Millisecond)
	}
	d, cooling := b.coolingDown("qq")
	if !cooling {
		t.Fatal("一波失败之后应该在冷却中")
	}
	if d > 15*time.Second {
		t.Fatalf("同一个冷却窗口里的连发失败不该升档,期望仍是第一档 15s,实际 %s", d)
	}

	if d < 14*time.Second {
		t.Fatalf("冷却不该被窗口内的失败续期(还剩 %s,说明 until 被往后推了)", d)
	}

	clk.advance(15 * time.Second)
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	if got, _ := b.coolingDown("qq"); got != 30*time.Second {
		t.Fatalf("冷却过期后的新一轮失败应升到 30s,实际 %s", got)
	}

	b.observe("c.y.qq.com", nil, 200, "")
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	if got, _ := b.coolingDown("qq"); got != 15*time.Second {
		t.Fatalf("成功清零后应从第一档 15s 重新开始,实际 %s", got)
	}
}

func TestLyricSourceBreakerIgnoresCanceledAnd4xx(t *testing.T) {
	b, _ := newTestBreaker()
	for i := 0; i < 5; i++ {
		b.observe("c.y.qq.com", context.Canceled, 0, "")
	}
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("context.Canceled 不该计入失败")
	}
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	b.observe("c.y.qq.com", nil, 403, "")
	b.observe("c.y.qq.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("403 之后计数应已清零,再一次失败不该熔断——403 不做粘性冷却")
	}
	b.observe("krcs.kugou.com", errProbeDial, 0, "")
	b.observe("krcs.kugou.com", errProbeDial, 0, "")
	if _, cooling := b.coolingDown("qq"); cooling {
		t.Fatal("酷狗的失败不该连累 QQ")
	}
	if _, cooling := b.coolingDown("kugou"); !cooling {
		t.Fatal("酷狗自己两次失败应熔断")
	}
	b.observe("ws.audioscrobbler.com", errProbeDial, 0, "")
	b.observe("ws.audioscrobbler.com", errProbeDial, 0, "")
	for _, s := range lyricSourceNames {
		if s == "kugou" {
			continue
		}
		if _, cooling := b.coolingDown(s); cooling {
			t.Fatalf("Last.fm 的失败不该影响任何歌词源,%s 却在冷却", s)
		}
	}
}

func TestClassifyLyricSourceTransportFailure(t *testing.T) {
	dnsNotFound := &url.Error{Op: "Get", URL: "https://music.163.com/x", Err: &net.OpError{
		Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "music.163.com", IsNotFound: true}}}
	dnsTimeout := &url.Error{Op: "Get", Err: &net.OpError{
		Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "i/o timeout", Name: "lrclib.net", IsTimeout: true}}}
	connRefused := &url.Error{Op: "Get", Err: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}}
	deadline := &url.Error{Op: "Get", Err: context.DeadlineExceeded}

	clientTimeout := &url.Error{Op: "Get", URL: "https://music.163.com/x",
		Err: errors.New("context deadline exceeded (Client.Timeout exceeded while awaiting headers)")}
	none := transportTrace{}
	dnsHung := transportTrace{dnsStarted: true}
	dnsFailedTr := transportTrace{dnsStarted: true, dnsDone: true, dnsErr: errors.New("lookup: i/o timeout")}
	dnsOK := transportTrace{dnsStarted: true, dnsDone: true}
	cases := []struct {
		name   string
		err    error
		status int
		tr     transportTrace
		want   string
	}{
		{"NXDOMAIN(错误链)", dnsNotFound, 0, none, lyricFailureReasonDNSFailed},
		{"解析器自身超时(错误链)", dnsTimeout, 0, none, lyricFailureReasonDNSFailed},
		{"连接被拒", connRefused, 0, none, lyricFailureReasonConnectFailed},
		{"读响应超时", deadline, 0, none, lyricFailureReasonConnectFailed},
		{"裸 EOF", io.EOF, 0, none, lyricFailureReasonConnectFailed},
		{"Client.Timeout 掐断 + DNS 没走完 → dns", clientTimeout, 0, dnsHung, lyricFailureReasonDNSFailed},
		{"Client.Timeout 掐断 + DNSDone 带错 → dns", clientTimeout, 0, dnsFailedTr, lyricFailureReasonDNSFailed},
		{"Client.Timeout 掐断 + DNS 已走完 → connect", clientTimeout, 0, dnsOK, lyricFailureReasonConnectFailed},
		{"读超时 + DNS 已走完 → connect", deadline, 0, dnsOK, lyricFailureReasonConnectFailed},
		{"轨迹 DNS 没走完但错误链是 NXDOMAIN → dns", dnsNotFound, 0, dnsHung, lyricFailureReasonDNSFailed},
		{"503", nil, 503, none, lyricFailureReasonServerError},
		{"500", nil, 500, none, lyricFailureReasonServerError},
		{"200", nil, 200, none, ""},
		{"404 也是响应", nil, 404, none, ""},
		{"429 也是响应", nil, 429, none, ""},
		{"200 但轨迹 DNS 带错(不可能的组合,响应优先)", nil, 200, dnsFailedTr, ""},
	}
	for _, c := range cases {
		if got := classifyLyricSourceTransportFailure(c.err, c.status, c.tr); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestLyricSourceBreakerObserveTraced(t *testing.T) {
	b, _ := newTestBreaker()
	clientTimeout := &url.Error{Op: "Get", Err: errors.New("context deadline exceeded (Client.Timeout exceeded while awaiting headers)")}
	b.observeTraced("music.163.com", clientTimeout, 0, "", transportTrace{dnsStarted: true})
	b.observeTraced("c.y.qq.com", clientTimeout, 0, "", transportTrace{dnsStarted: true, dnsDone: true})
	got := b.transportFailureCodes()
	if got["netease"] != lyricFailureReasonDNSFailed {
		t.Errorf("netease: got %q want dns_failed(轨迹 DNS 未结束)", got["netease"])
	}
	if got["qq"] != lyricFailureReasonConnectFailed {
		t.Errorf("qq: got %q want connect_failed(轨迹 DNS 已结束)", got["qq"])
	}
}

func TestLyricSourceTransportFailureCodes(t *testing.T) {
	b, _ := newTestBreaker()
	dns := &url.Error{Op: "Get", Err: &net.OpError{Op: "dial", Err: &net.DNSError{Err: "no such host", IsNotFound: true}}}
	timeout := &url.Error{Op: "Get", Err: context.DeadlineExceeded}

	if got := b.transportFailureCodes(); got != nil {
		t.Fatalf("空表应返回 nil,得到 %v", got)
	}

	for i := 0; i < 4; i++ {
		b.observe("music.163.com", dns, 0, "")
	}

	b.observe("c.y.qq.com", dns, 0, "")
	b.observe("c.y.qq.com", timeout, 0, "")
	b.observe("u.y.qq.com", timeout, 0, "")

	b.observe("mobilecdn.kugou.com", timeout, 0, "")
	b.observe("mobilecdn.kugou.com", dns, 0, "")

	b.observe("lrclib.net", nil, 503, "")
	b.observe("lrclib.net", nil, 502, "")

	b.observe("search.kuwo.cn", dns, 0, "")
	b.observe("search.kuwo.cn", nil, 404, "")

	b.observe("pd.musicapp.migu.cn", nil, 503, "")
	b.observe("pd.musicapp.migu.cn", nil, 200, "")

	b.observe("apic-appmobile.musixmatch.com", context.Canceled, 0, "")

	b.observe("ws.audioscrobbler.com", dns, 0, "")
	b.observe("itunes.apple.com", dns, 0, "")

	got := b.transportFailureCodes()
	want := map[string]string{
		"netease": lyricFailureReasonDNSFailed,
		"qq":      lyricFailureReasonConnectFailed,
		"kugou":   lyricFailureReasonDNSFailed,
		"lrclib":  lyricFailureReasonServerError,
	}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for s, code := range want {
		if got[s] != code {
			t.Errorf("%s: got %q want %q(全部:%v)", s, got[s], code, got)
		}
	}

	if _, cooling := b.coolingDown("netease"); !cooling {
		t.Error("网易云 4 次失败应在冷却")
	}
	if _, cooling := b.coolingDown("migu"); cooling {
		t.Error("咪咕最后一次成功,不该冷却")
	}

	b.observe("music.163.com", nil, 200, "")
	if _, still := b.transportFailureCodes()["netease"]; still {
		t.Error("网易云拿到响应后不该再报 dns_failed")
	}
}

func TestLyricSourceBreakerRetryAfter(t *testing.T) {
	cases := map[string]time.Duration{
		"":                              time.Minute,
		"120":                           2 * time.Minute,
		" 30 ":                          30 * time.Second,
		"99999":                         5 * time.Minute,
		"0":                             time.Minute,
		"Wed, 21 Oct 2026 07:28:00 GMT": time.Minute,
	}
	for header, want := range cases {
		b, _ := newTestBreaker()
		b.observe("lrclib.net", nil, 429, header)
		if d, cooling := b.coolingDown("lrclib"); !cooling || d != want {
			t.Errorf("Retry-After %q: cooling=%v d=%s, want %s", header, cooling, d, want)
		}
	}
}

func TestLyricSourceBreakerPlanRoundNeverSkipsAllEnabled(t *testing.T) {
	b, _ := newTestBreaker()
	trip := func(host string) {
		b.observe(host, errProbeDial, 0, "")
		b.observe(host, errProbeDial, 0, "")
	}
	trip("music.163.com")
	trip("c.y.qq.com")
	onlyTwo := func(s string) bool { return s == "netease" || s == "qq" }
	if plan := b.planRound(lyricSourceNames, onlyTwo); plan != nil {
		t.Fatalf("启用的两个源都在冷却时应谁也不跳过,实际 %v", plan)
	}
	allOn := func(string) bool { return true }
	plan := b.planRound(lyricSourceNames, allOn)
	if len(plan) != 2 || plan["netease"] == 0 || plan["qq"] == 0 {
		t.Fatalf("全源全开时应只跳过冷却中的两个,实际 %v", plan)
	}
	if _, ok := plan["kugou"]; ok {
		t.Fatal("没冷却的源不该在跳过名单里")
	}

	onlyKugou := func(s string) bool { return s == "kugou" }
	plan = b.planRound(lyricSourceNames, onlyKugou)
	if len(plan) != 2 {
		t.Fatalf("未启用的冷却源也应跳过,实际 %v", plan)
	}

	b2, _ := newTestBreaker()
	if plan := b2.planRound(lyricSourceNames, allOn); plan != nil {
		t.Fatalf("无冷却时应返回 nil,实际 %v", plan)
	}
}

func TestLyricSourceRoundViaContext(t *testing.T) {
	ctx, round := withLyricSourceRound(context.Background())
	got := lyricSourceRoundFrom(ctx)
	if got != round {
		t.Fatal("ctx 里取不回同一个 round")
	}
	got.markSkipped("qq")
	got.markSkipped("netease")
	got.markSkipped("qq")
	if s := round.skippedSources(); len(s) != 2 || s[0] != "netease" || s[1] != "qq" {
		t.Fatalf("skippedSources 应去重且排序,实际 %v", s)
	}
	var nilRound *lyricSourceRound
	nilRound.markSkipped("kugou")
	if nilRound.skippedSources() != nil {
		t.Fatal("nil round 应返回 nil")
	}
	if lyricSourceRoundFrom(context.Background()) != nil {
		t.Fatal("没挂 round 的 ctx 应返回 nil")
	}
	if withoutSkips, _ := withLyricSourceRound(context.Background()); lyricSourceRoundFrom(withoutSkips).skippedSources() != nil {
		t.Fatal("没跳过任何源时应返回 nil,而不是空切片(写进 JSON 会变成 [])")
	}
}

func TestNeedsLyricsFirstFillShortIntervalWhenSourcesSkipped(t *testing.T) {
	orig := anyLyricSourceCooling
	defer func() { anyLyricSourceCooling = orig }()

	now := time.Now().Unix()

	anyLyricSourceCooling = func([]string) bool { return true }
	skipped := enrichEntry{TS: now - 11*60, LyricsSourcesSkipped: []string{"netease"}}
	if !needsLyricsFirstFill(skipped) {
		t.Fatal("有源被跳过、11 分钟后应重试")
	}
	tooSoon := enrichEntry{TS: now - 5*60, LyricsSourcesSkipped: []string{"netease"}}
	if needsLyricsFirstFill(tooSoon) {
		t.Fatal("源还在冷却中,5 分钟还不到 10 分钟的间隔")
	}
	plain := enrichEntry{TS: now - 11*60}
	if needsLyricsFirstFill(plain) {
		t.Fatal("没有源被跳过时仍是 24 小时起步")
	}
	retried := enrichEntry{TS: now - 11*60, LyricsFillTS: now - 11*60, LyricsFillCount: 1, LyricsSourcesSkipped: []string{"netease"}}
	if needsLyricsFirstFill(retried) {
		t.Fatal("补过一次之后应回到正常退避")
	}

	anyLyricSourceCooling = func([]string) bool { return false }
	ready := enrichEntry{TS: now - 31, LyricsSourcesSkipped: []string{"netease"}}
	if !needsLyricsFirstFill(ready) {
		t.Fatal("被跳过的源都不冷却了,31 秒后就该补搜")
	}
	tooFresh := enrichEntry{TS: now - 10, LyricsSourcesSkipped: []string{"netease"}}
	if needsLyricsFirstFill(tooFresh) {
		t.Fatal("10 秒还不到 30 秒——那 30 秒是给抖动型故障留的观察期,不能省")
	}

	if needsLyricsFirstFill(enrichEntry{TS: now - 31, LyricsFillCount: 1, LyricsSourcesSkipped: []string{"netease"}}) {
		t.Fatal("补过一次之后不该再走 30 秒这一档")
	}
	if needsLyricsFirstFill(enrichEntry{TS: now - 31}) {
		t.Fatal("没有源被跳过的条目不该因为熔断器是空的就被拉进快速档")
	}
}
