package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestBatchRunningProcessesConcurrentStress tests batchRunningProcesses under
// heavy concurrent load with diverse candidate name patterns (known players,
// non-existent processes, unicode names, and regex metacharacters).
func TestBatchRunningProcessesConcurrentStress(t *testing.T) {
	const (
		concurrency = 12
		iterations  = 8
	)

	testCandidates := [][]string{
		{"Music", "QQMusic", "NeteaseMusic", "Spotify", "酷狗音乐"},
		{"NonExistentProc_1", "NonExistentProc_2", "NonExistentProc_3"},
		{"酷狗音乐", "测试进程", "音乐"},
		{"proc.with.dot", "proc[0-9]", "proc|pipe", "proc+plus*star"},
		{"zsh", "bash", "go", "collector"},
		{},
	}

	var wg sync.WaitGroup
	errCh := make(chan error, concurrency*iterations)

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		goroutineID := i
		go func() {
			defer wg.Done()
			for it := 0; it < iterations; it++ {
				cands := testCandidates[(goroutineID+it)%len(testCandidates)]
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				running, err := batchRunningProcesses(ctx, cands)
				cancel()
				if err != nil {
					errCh <- fmt.Errorf("goroutine %d iter %d: batchRunningProcesses failed: %w", goroutineID, it, err)
					return
				}
				// Verify map structure
				for name, isRun := range running {
					if !isRun {
						errCh <- fmt.Errorf("unexpected false entry in running map for %s", name)
						return
					}
				}
				// Verify non-existent processes are never marked running
				if running["NonExistentProc_1"] || running["NonExistentProc_2"] {
					errCh <- fmt.Errorf("bogus process marked as running")
					return
				}
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Fatal(err)
	}
}

// TestBatchRunningProcessesContextCancellation verifies batchRunningProcesses
// honors pre-cancelled and fast-timeout contexts without hanging or leaking.
func TestBatchRunningProcessesContextCancellation(t *testing.T) {
	// Pre-cancelled context
	canceledCtx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := batchRunningProcesses(canceledCtx, []string{"Music", "Spotify"})
	if err == nil {
		t.Errorf("expected error with pre-cancelled context, got nil")
	}

	// Micro-timeout context
	timeoutCtx, timeoutCancel := context.WithTimeout(context.Background(), 1*time.Nanosecond)
	defer timeoutCancel()
	time.Sleep(2 * time.Millisecond) // Ensure timeout expires

	_, err = batchRunningProcesses(timeoutCtx, []string{"Music", "Spotify"})
	if err == nil {
		t.Errorf("expected error with expired timeout context, got nil")
	}
}

// TestCheckCompanionLaunchBypassStateTransitions verifies the transition logic
// when companion launch feature is toggled between enabled and disabled.
func TestCheckCompanionLaunchBypassStateTransitions(t *testing.T) {
	savedEnabled := features.LaunchLyrimuseOnMusicOpen
	savedLastRunning := lastRunningByName
	savedWasEnabled := wasCompanionEnabled
	savedPlayers := features.Players
	defer func() {
		features.LaunchLyrimuseOnMusicOpen = savedEnabled
		lastRunningByName = savedLastRunning
		wasCompanionEnabled = savedWasEnabled
		features.Players = savedPlayers
	}()

	features.Players = map[string]bool{playerAuto: true}
	ctx := context.Background()

	// 1. When disabled, checkCompanionLaunch clears state and sets wasCompanionEnabled to false
	features.LaunchLyrimuseOnMusicOpen = false
	lastRunningByName = map[string]bool{"Music": true, "Spotify": true}
	wasCompanionEnabled = true

	checkCompanionLaunch(ctx)
	if len(lastRunningByName) != 0 {
		t.Errorf("expected lastRunningByName to be cleared, got %v", lastRunningByName)
	}
	if wasCompanionEnabled {
		t.Errorf("expected wasCompanionEnabled to be false when disabled")
	}

	// 2. Toggle to enabled: first check must initialize baseline state without launching
	features.LaunchLyrimuseOnMusicOpen = true
	wasCompanionEnabled = false
	lastRunningByName = map[string]bool{}

	checkCompanionLaunch(ctx)
	if !wasCompanionEnabled {
		t.Errorf("expected wasCompanionEnabled to become true on first check after enable")
	}

	// 3. Repeated check with no new processes running must not trigger launch
	checkCompanionLaunch(ctx)
	if !wasCompanionEnabled {
		t.Errorf("wasCompanionEnabled should remain true")
	}

	// 4. Toggle back to disabled
	features.LaunchLyrimuseOnMusicOpen = false
	checkCompanionLaunch(ctx)
	if wasCompanionEnabled {
		t.Errorf("wasCompanionEnabled should be reset to false when disabled")
	}
	if len(lastRunningByName) != 0 {
		t.Errorf("lastRunningByName should be cleared when disabled, got %v", lastRunningByName)
	}
}

// TestLyricHTTPClientConcurrentCaching verifies that concurrent requests for
// lyric HTTP clients with various timeouts correctly reuse client singletons
// without race conditions or pointer discrepancies.
func TestLyricHTTPClientConcurrentCaching(t *testing.T) {
	const goroutines = 40
	const iterations = 50
	timeouts := []time.Duration{
		3 * time.Second,
		5 * time.Second,
		6 * time.Second,
		10 * time.Second,
	}

	var wg sync.WaitGroup
	errCh := make(chan error, goroutines)

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				for _, d := range timeouts {
					c1 := lyricHTTPClient(d)
					c2 := lyricHTTPClient(d)
					if c1 != c2 {
						errCh <- fmt.Errorf("expected cached pointer reuse for timeout %v, got %p vs %p", d, c1, c2)
						return
					}
					if c1.Timeout != d {
						errCh <- fmt.Errorf("client timeout mismatch: want %v, got %v", d, c1.Timeout)
						return
					}
				}
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Fatal(err)
	}
}

// TestFilesystemPollingStatShortCircuit verifies that checkEnrichCancelRequest
// and readLyricsFillRequest short-circuit cleanly without error when request
// files do not exist.
func TestFilesystemPollingStatShortCircuit(t *testing.T) {
	savedCancelPath := enrichCancelRequestPath
	savedFillPath := lyricsFillRequestPath
	defer func() {
		enrichCancelRequestPath = savedCancelPath
		lyricsFillRequestPath = savedFillPath
	}()

	enrichCancelRequestPath = "/nonexistent/path/for/enrich_cancel_test.txt"
	lyricsFillRequestPath = "/nonexistent/path/for/lyrics_fill_test.txt"

	// Should not panic, fail, or open file
	for i := 0; i < 20; i++ {
		checkEnrichCancelRequest()
		req, ok := readLyricsFillRequest()
		if ok || req.all || len(req.keys) > 0 {
			t.Errorf("expected false/empty from readLyricsFillRequest for nonexistent file")
		}
	}
}

