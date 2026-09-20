package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestProvablyNeverSent(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{

			name: "DNS 解析失败 = 确定没发出去",
			err:  fmt.Errorf("post: %w", &net.DNSError{Err: "no such host", Name: "ws.audioscrobbler.com"}),
			want: true,
		},
		{
			name: "dial 阶段失败 = 确定没发出去",
			err:  fmt.Errorf("post: %w", &net.OpError{Op: "dial", Err: errors.New("connection refused")}),
			want: true,
		},
		{

			name: "read 阶段失败 = 不确定,必须判 false",
			err:  fmt.Errorf("post: %w", &net.OpError{Op: "read", Err: errors.New("no route to host")}),
			want: false,
		},
		{

			name: "context deadline = 不确定,必须判 false",
			err:  fmt.Errorf("post: %w", context.DeadlineExceeded),
			want: false,
		},
		{
			name: "应用层错误 = 服务端已表态,不是没发出去",
			err:  &lastfmAPIError{Code: 11, Message: "Service Offline", Method: "track.scrobble"},
			want: false,
		},
		{
			name: "普通错误",
			err:  errors.New("boom"),
			want: false,
		},
	}
	for _, c := range cases {
		if got := provablyNeverSent(c.err); got != c.want {
			t.Errorf("%s: provablyNeverSent(%v) = %v, want %v", c.name, c.err, got, c.want)
		}
	}
}

func TestRecordFailedMirrorRouting(t *testing.T) {
	countByType := func(t *testing.T) (l, q int) {
		t.Helper()
		for _, line := range readListenLog() {
			switch line.T {
			case "l":
				l++
			case "q":
				q++
			}
		}
		return
	}

	t.Run("确定没发出去 → 只写 l,回填会正常挑走", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		uts := time.Now().Add(-time.Hour).Unix()
		recordFailedMirror(
			fmt.Errorf("post: %w", &net.DNSError{Err: "no such host"}),
			"周杰倫", "七里香", "七里香", uts, 300)

		l, q := countByType(t)
		if l != 1 || q != 0 {
			t.Fatalf("want 1 listen + 0 quarantine, got l=%d q=%d", l, q)
		}
		pending, _ := pendingBackfillListens(time.Now())
		if len(pending) != 1 {
			t.Fatalf("确定没发出去的这条必须能被回填挑走, got %d pending", len(pending))
		}

		if pending[0].AR != "周杰倫" {
			t.Fatalf("AR 必须是原始标签, got %q", pending[0].AR)
		}
	})

	t.Run("不确定发没发到 → 写 l+q,且回填绝不自动重试", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		uts := time.Now().Add(-time.Hour).Unix()
		recordFailedMirror(
			fmt.Errorf("post: %w", context.DeadlineExceeded),
			"周杰倫", "七里香", "七里香", uts, 300)

		l, q := countByType(t)
		if l != 1 || q != 1 {
			t.Fatalf("want 1 listen + 1 quarantine, got l=%d q=%d", l, q)
		}

		if pending, _ := pendingBackfillListens(time.Now()); len(pending) != 0 {
			t.Fatalf("隔离的条目绝不能被自动回填, got %d pending", len(pending))
		}
	})

	t.Run("服务端拒收内容本身(accepted=0) → 什么都不写", func(t *testing.T) {
		dir := t.TempDir()
		saved := listenLogPath
		defer func() { listenLogPath = saved }()
		listenLogPath = filepath.Join(dir, "l.jsonl")

		recordFailedMirror(
			&lastfmIgnoredError{Method: "track.scrobble", Reason: "1 Artist was ignored"},
			"群星", "这样吧", "烧的时尚", time.Now().Unix(), 200)

		if l, q := countByType(t); l != 0 || q != 0 {
			t.Fatalf("内容被拒收不该留痕, got l=%d q=%d", l, q)
		}
	})

	t.Run("应用层错误按 mayHaveStored 分档,绝不一律丢弃", func(t *testing.T) {
		cases := []struct {
			name    string
			code    int
			wantQ   int
			because string
		}{
			{"限流 29 = 确定没落库,该留痕待补", 29, 0, "服务端明确拒绝了这次写入"},
			{"凭据失效 9 = 确定没落库,该留痕待补", 9, 0, "重新授权后正该靠回填补回来"},
			{"服务不可用 11 = 可能已落库,必须隔离", 11, 1, "重发是最大的自造重复源"},
			{"服务不可用 16 = 可能已落库,必须隔离", 16, 1, "同 11"},
		}
		for _, c := range cases {
			dir := t.TempDir()
			saved := listenLogPath
			listenLogPath = filepath.Join(dir, "l.jsonl")

			recordFailedMirror(
				&lastfmAPIError{Code: c.code, Message: "x", Method: "track.scrobble"},
				"周杰倫", "七里香", "七里香", time.Now().Add(-time.Hour).Unix(), 300)
			l, q := countByType(t)
			listenLogPath = saved

			if l != 1 {
				t.Errorf("%s: 必须留痕(%s), got l=%d", c.name, c.because, l)
			}
			if q != c.wantQ {
				t.Errorf("%s: quarantine 应为 %d(%s), got %d", c.name, c.wantQ, c.because, q)
			}
		}
	})
}

func TestLastfmAPIErrorMayHaveStored(t *testing.T) {
	cases := []struct {
		code int
		want bool
		why  string
	}{
		{11, true, "Service Offline:服务端可能已落库、只是回执丢了"},
		{16, true, "temporarily unavailable:同 11"},
		{29, false, "限流:服务端明确拒绝了这次写入,确定没落库"},
		{4, false, "Authentication Failed:没通过鉴权,确定没落库"},
		{9, false, "Invalid session key:同上"},
		{10, false, "Invalid API key:同上"},
		{26, false, "API key suspended:同上"},
		{6, false, "参数错误:服务端表过态,确定没落库"},
	}
	for _, c := range cases {
		e := &lastfmAPIError{Code: c.code, Method: "track.scrobble"}
		if got := e.mayHaveStored(); got != c.want {
			t.Errorf("error %d: mayHaveStored() = %v, want %v (%s)", c.code, got, c.want, c.why)
		}
	}
}

func TestIgnoredReason(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "带 code 和人话原因",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"1","#text":"Artist was ignored"}}`,
			want: "1 Artist was ignored",
		},
		{
			name: "只有 code",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"6","#text":""}}`,
			want: "code 6",
		},
		{

			name: "code 0 不当原因",
			raw:  `{"timestamp":"1","ignoredMessage":{"code":"0","#text":""}}`,
			want: "",
		},
		{
			name: "解不开时返回空,调用方那句 accepted=0 本身仍然可用",
			raw:  `"garbage"`,
			want: "",
		},
	}
	for _, c := range cases {
		if got := ignoredReason(json.RawMessage(c.raw)); got != c.want {
			t.Errorf("%s: ignoredReason() = %q, want %q", c.name, got, c.want)
		}
	}
}
