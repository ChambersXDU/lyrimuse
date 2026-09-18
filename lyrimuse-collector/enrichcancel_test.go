package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCheckEnrichCancelRequest(t *testing.T) {
	tmpDir := t.TempDir()
	reqPath := filepath.Join(tmpDir, "enrich-cancel.txt")
	setEnrichCancelRequestPath(reqPath)

	// File doesn't exist: checkEnrichCancelRequest should exit cleanly without panic
	checkEnrichCancelRequest()

	// Register a cancel func
	cancelled := false
	cancelKey := "Artist|Title|Album"
	enrichMu.Lock()
	enrichCancelFuncs[cancelKey] = func() {
		cancelled = true
	}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		delete(enrichCancelFuncs, cancelKey)
		enrichMu.Unlock()
	})

	// Write cancel request file
	if err := os.WriteFile(reqPath, []byte(cancelKey), 0o644); err != nil {
		t.Fatal(err)
	}

	checkEnrichCancelRequest()

	if !cancelled {
		t.Errorf("expected cancel func to be called for key %q", cancelKey)
	}

	// File should be consumed and deleted
	if _, err := os.Stat(reqPath); !os.IsNotExist(err) {
		t.Errorf("expected cancel request file to be removed after check, got err: %v", err)
	}
}

func TestStartEnrichCancelWatcherCleanExit(t *testing.T) {
	tmpDir := t.TempDir()
	reqPath := filepath.Join(tmpDir, "enrich-cancel-exit.txt")
	setEnrichCancelRequestPath(reqPath)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		startEnrichCancelWatcher(ctx)
		close(done)
	}()

	cancel()
	select {
	case <-done:
		// Clean exit
	case <-time.After(1 * time.Second):
		t.Fatal("startEnrichCancelWatcher did not exit promptly on ctx.Done()")
	}
}

func TestResolveEnrichAsyncCancelWritesNoLyricsEntry(t *testing.T) {
	savedCache, savedPath, savedDirty := enrichCache, enrichPath, enrichDirty
	savedInflight, savedCancelFuncs := enrichInflight, enrichCancelFuncs
	t.Cleanup(func() {
		enrichCache, enrichPath, enrichDirty = savedCache, savedPath, savedDirty
		enrichInflight, enrichCancelFuncs = savedInflight, savedCancelFuncs
	})
	enrichCache = map[string]enrichEntry{}
	enrichPath = "" // 纯内存断言,不触碰磁盘——saveEnrichCache 在空路径时是安全的空操作
	enrichInflight = map[string]bool{}
	enrichCancelFuncs = map[string]context.CancelFunc{}

	const artist, title, album = "某测试歌手不存在", "某测试歌名不存在", ""
	key := enrichKey(artist, title, album)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 调用前就取消——模拟"停止搜索"按钮点下去、enrichcancel.go 的 watcher 已经调过 cancel

	done := make(chan struct{})
	go func() {
		resolveEnrichAsync(ctx, key, artist, title, album, "", 0, false)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("resolveEnrichAsync 在已取消的 ctx 下没能在 10s 内返回——可能哪个网络调用没有正确接住 ctx.Done()")
	}

	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok {
		t.Fatalf("取消之后应该保留一条记录(标记为暂无歌词),但 enrichCache 里完全没有 key=%q", key)
	}
	if e.Lyrics != "" {
		t.Errorf("取消场景下不该凑巧真的解析出歌词,got lyrics=%q", e.Lyrics)
	}
	if e.TS <= 0 {
		t.Errorf("TS 必须 > 0——EnrichCacheReader.lookup 靠它判定'这一轮解析真的跑完了',否则灵动岛/悬浮歌词会一直卡在'搜索歌词中…'")
	}
}

