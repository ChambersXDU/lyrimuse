package main

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestMusixmatchEnsureTokenSingleFlight(t *testing.T) {

	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = ""
	musixmatchTokenExpiry = time.Time{}
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()

	var calls int32
	musixmatchDoFetchToken = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)

		time.Sleep(30 * time.Millisecond)
		musixmatchTokenMu.Lock()
		musixmatchToken = "tok-A"
		musixmatchTokenExpiry = time.Now().Add(9 * time.Minute)
		musixmatchTokenMu.Unlock()
		return "tok-A"
	}

	const n = 16
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = musixmatchEnsureToken(context.Background())
		}(i)
	}
	wg.Wait()

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("单飞失效: %d 个并发调用触发了 %d 次真实换 token(应为 1)", n, got)
	}
	for i, r := range results {
		if r != "tok-A" {
			t.Errorf("goroutine %d 拿到的 token 不对: 实际 %q,期望 %q", i, r, "tok-A")
		}
	}
}

func TestMusixmatchEnsureTokenSkipsFetchWhenCached(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = "tok-fresh"
	musixmatchTokenExpiry = time.Now().Add(5 * time.Minute)
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()
	musixmatchDoFetchToken = func(ctx context.Context) string {
		t.Error("token 仍在有效期内,不该去真的换")
		return "should-not-happen"
	}

	const n = 8
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = musixmatchEnsureToken(context.Background())
		}(i)
	}
	wg.Wait()

	for i, r := range results {
		if r != "tok-fresh" {
			t.Errorf("goroutine %d 拿到的 token 不对: 实际 %q,期望 %q", i, r, "tok-fresh")
		}
	}
}

func TestMusixmatchEnsureTokenRefreshesAfterExpiry(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = "tok-old"
	musixmatchTokenExpiry = time.Now().Add(-time.Second)
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()
	var calls int32
	musixmatchDoFetchToken = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)
		musixmatchTokenMu.Lock()
		musixmatchToken = "tok-new"
		musixmatchTokenExpiry = time.Now().Add(9 * time.Minute)
		musixmatchTokenMu.Unlock()
		return "tok-new"
	}

	if got := musixmatchEnsureToken(context.Background()); got != "tok-new" {
		t.Fatalf("过期后应该换到新 token,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("应该真的换了一次,实际触发 %d 次", got)
	}

	if got := musixmatchEnsureToken(context.Background()); got != "tok-new" {
		t.Fatalf("第二次调用应该复用新 token,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("第二次调用不该再触发刷新,累计应仍为 1,实际 %d", got)
	}
}
