package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestAppleAlbumHintSyncConcurrentSameKeyStress tests 60 concurrent callers requesting
// the same key while an in-flight query is pending. When storeAppleAlbumHintResult
// finishes, all callers must receive the exact expected album cleanly and without race.
func TestAppleAlbumHintSyncConcurrentSameKeyStress(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("StressArtist", "StressSong", 180)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{key: true}
	waitCh := make(chan struct{})
	appleAlbumHintWaiters = map[string]chan struct{}{key: waitCh}
	appleAlbumHintLogged = map[string]string{}

	const numWaiters = 60
	results := make([]string, numWaiters)
	var wg sync.WaitGroup

	ctx := context.Background()
	for i := 0; i < numWaiters; i++ {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()
			results[idx] = appleAlbumHintSync(ctx, "StressArtist", "StressSong", 180, nil)
		}()
	}

	// Allow goroutines to enter appleAlbumHintSync and park on waitCh
	time.Sleep(50 * time.Millisecond)

	// Simulate background completion
	expectedAlbum := "StressAlbumResult"
	testCands := []albumHintCandidate{
		{Artist: "StressArtist", Album: expectedAlbum},
	}
	storeAppleAlbumHintResult(key, testCands, true)

	wg.Wait()

	for i, res := range results {
		if res != expectedAlbum {
			t.Errorf("waiter %d got %q, want %q", i, res, expectedAlbum)
		}
	}

	// Verify state cleanup
	appleAlbumHintMu.Lock()
	defer appleAlbumHintMu.Unlock()
	if appleAlbumHintInflight[key] {
		t.Errorf("expected inflight to be false after completion")
	}
	if _, exists := appleAlbumHintWaiters[key]; exists {
		t.Errorf("expected waiter channel to be removed from map after completion")
	}
}

// TestAppleAlbumHintSyncConcurrentDifferentKeysStress tests 10 distinct keys with 5
// concurrent callers each (50 total goroutines). Each key is resolved independently
// with staggered completion to verify isolation and lack of cross-talk.
func TestAppleAlbumHintSyncConcurrentDifferentKeysStress(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	const numKeys = 10
	const callersPerKey = 5

	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintWaiters = map[string]chan struct{}{}
	appleAlbumHintLogged = map[string]string{}

	keys := make([]string, numKeys)
	for k := 0; k < numKeys; k++ {
		artist := fmt.Sprintf("Artist_%d", k)
		title := fmt.Sprintf("Title_%d", k)
		key := appleAlbumHintKey(artist, title, 200)
		keys[k] = key
		appleAlbumHintInflight[key] = true
		appleAlbumHintWaiters[key] = make(chan struct{})
	}

	results := make([][]string, numKeys)
	for k := 0; k < numKeys; k++ {
		results[k] = make([]string, callersPerKey)
	}

	var wg sync.WaitGroup
	ctx := context.Background()

	for k := 0; k < numKeys; k++ {
		for c := 0; c < callersPerKey; c++ {
			wg.Add(1)
			keyIdx := k
			callerIdx := c
			artist := fmt.Sprintf("Artist_%d", keyIdx)
			title := fmt.Sprintf("Title_%d", keyIdx)
			go func() {
				defer wg.Done()
				results[keyIdx][callerIdx] = appleAlbumHintSync(ctx, artist, title, 200, nil)
			}()
		}
	}

	time.Sleep(30 * time.Millisecond)

	// Resolve each key in a staggered manner
	for k := 0; k < numKeys; k++ {
		expectedAlbum := fmt.Sprintf("Album_%d", k)
		artist := fmt.Sprintf("Artist_%d", k)
		cands := []albumHintCandidate{
			{Artist: artist, Album: expectedAlbum},
		}
		storeAppleAlbumHintResult(keys[k], cands, true)
		time.Sleep(5 * time.Millisecond)
	}

	wg.Wait()

	for k := 0; k < numKeys; k++ {
		expected := fmt.Sprintf("Album_%d", k)
		for c := 0; c < callersPerKey; c++ {
			if results[k][c] != expected {
				t.Errorf("key %d caller %d got %q, want %q", k, c, results[k][c], expected)
			}
		}
	}
}

// TestAppleAlbumHintSyncContextCancellationAndTimeoutStress verifies that waiters with
// expired or canceled contexts unblock cleanly without hanging other waiters on the
// same channel.
func TestAppleAlbumHintSyncContextCancellationAndTimeoutStress(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("CancelArtist", "CancelTitle", 210)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{key: true}
	waitCh := make(chan struct{})
	appleAlbumHintWaiters = map[string]chan struct{}{key: waitCh}
	appleAlbumHintLogged = map[string]string{}

	const canceledCount = 15
	const persistentCount = 15

	canceledResults := make([]string, canceledCount)
	persistentResults := make([]string, persistentCount)

	var wg sync.WaitGroup

	// Launch callers with early-canceling contexts
	for i := 0; i < canceledCount; i++ {
		wg.Add(1)
		idx := i
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		go func() {
			defer wg.Done()
			defer cancel()
			canceledResults[idx] = appleAlbumHintSync(ctx, "CancelArtist", "CancelTitle", 210, nil)
		}()
	}

	// Launch callers with standard non-canceling contexts
	for i := 0; i < persistentCount; i++ {
		wg.Add(1)
		idx := i
		ctx := context.Background()
		go func() {
			defer wg.Done()
			persistentResults[idx] = appleAlbumHintSync(ctx, "CancelArtist", "CancelTitle", 210, nil)
		}()
	}

	// Allow canceled callers to time out at 20ms
	time.Sleep(60 * time.Millisecond)

	// Now complete the background task for the persistent callers
	expectedAlbum := "ValidAlbumForPersistent"
	cands := []albumHintCandidate{
		{Artist: "CancelArtist", Album: expectedAlbum},
	}
	storeAppleAlbumHintResult(key, cands, true)

	wg.Wait()

	// Verify canceled callers returned ""
	for i, res := range canceledResults {
		if res != "" {
			t.Errorf("canceled waiter %d expected empty string, got %q", i, res)
		}
	}

	// Verify persistent callers received the album
	for i, res := range persistentResults {
		if res != expectedAlbum {
			t.Errorf("persistent waiter %d expected %q, got %q", i, expectedAlbum, res)
		}
	}
}

// TestAppleAlbumHintSyncEmptyCandidatesConcluded verifies that when a background
// query finishes with zero candidates, all parked callers return "" and do not hang.
func TestAppleAlbumHintSyncEmptyCandidatesConcluded(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("EmptyArtist", "EmptyTitle", 195)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{key: true}
	waitCh := make(chan struct{})
	appleAlbumHintWaiters = map[string]chan struct{}{key: waitCh}
	appleAlbumHintLogged = map[string]string{}

	const count = 10
	results := make([]string, count)
	var wg sync.WaitGroup

	ctx := context.Background()
	for i := 0; i < count; i++ {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()
			results[idx] = appleAlbumHintSync(ctx, "EmptyArtist", "EmptyTitle", 195, nil)
		}()
	}

	time.Sleep(30 * time.Millisecond)

	// Store empty candidates with concluded = true
	storeAppleAlbumHintResult(key, nil, true)

	wg.Wait()

	for i, res := range results {
		if res != "" {
			t.Errorf("waiter %d expected empty string on zero candidates, got %q", i, res)
		}
	}

	appleAlbumHintMu.Lock()
	defer appleAlbumHintMu.Unlock()
	if appleAlbumHintMisses[key] != 1 {
		t.Errorf("expected misses to be 1, got %d", appleAlbumHintMisses[key])
	}
}

// TestAppleAlbumHintAsyncAndSyncInteroperation tests the concurrent interoperation
// between appleAlbumHint (async fire-and-forget in poller) and appleAlbumHintSync
// (blocking wait in backend resolveTrackEnrichment).
func TestAppleAlbumHintAsyncAndSyncInteroperation(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("InterArtist", "InterTitle", 220)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintWaiters = map[string]chan struct{}{}
	appleAlbumHintLogged = map[string]string{}

	// 1. First caller is the async poller calling appleAlbumHint
	// We simulate this by setting inflight and waitCh as appleAlbumHint does
	appleAlbumHintMu.Lock()
	appleAlbumHintInflight[key] = true
	waitCh := make(chan struct{})
	appleAlbumHintWaiters[key] = waitCh
	appleAlbumHintMu.Unlock()

	// 2. Concurrently, 10 backend workers call appleAlbumHintSync
	const numSync = 10
	results := make([]string, numSync)
	var wg sync.WaitGroup
	ctx := context.Background()

	for i := 0; i < numSync; i++ {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()
			results[idx] = appleAlbumHintSync(ctx, "InterArtist", "InterTitle", 220, nil)
		}()
	}

	time.Sleep(30 * time.Millisecond)

	// 3. Poller background goroutine finishes fetch and stores result
	expectedAlbum := "InterAlbum"
	cands := []albumHintCandidate{
		{Artist: "InterArtist", Album: expectedAlbum},
	}
	storeAppleAlbumHintResult(key, cands, true)

	wg.Wait()

	for i, res := range results {
		if res != expectedAlbum {
			t.Errorf("sync caller %d got %q, want %q", i, res, expectedAlbum)
		}
	}
}

// TestAppleAlbumHintSyncMaxMissesImmediateBypass verifies that when a track has
// already reached appleAlbumHintMaxMisses, appleAlbumHintSync returns immediately
// without registering waiters or initiating queries.
func TestAppleAlbumHintSyncMaxMissesImmediateBypass(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("MissedArtist", "MissedTitle", 240)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{key: appleAlbumHintMaxMisses}
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintWaiters = map[string]chan struct{}{}
	appleAlbumHintLogged = map[string]string{}

	ctx := context.Background()
	start := time.Now()
	res := appleAlbumHintSync(ctx, "MissedArtist", "MissedTitle", 240, nil)
	elapsed := time.Since(start)

	if res != "" {
		t.Errorf("expected empty string for max misses reached, got %q", res)
	}
	if elapsed > 100*time.Millisecond {
		t.Errorf("expected immediate bypass, took %v", elapsed)
	}
	if len(appleAlbumHintWaiters) != 0 {
		t.Errorf("expected no waiters registered, got %v", appleAlbumHintWaiters)
	}
}

// TestAppleAlbumHintSyncPreCancelledContext verifies that calling appleAlbumHintSync
// with an already-canceled context while in-flight returns immediately without deadlock.
func TestAppleAlbumHintSyncPreCancelledContext(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("PreCancelArtist", "PreCancelTitle", 250)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{key: true}
	waitCh := make(chan struct{})
	appleAlbumHintWaiters = map[string]chan struct{}{key: waitCh}
	appleAlbumHintLogged = map[string]string{}

	canceledCtx, cancel := context.WithCancel(context.Background())
	cancel()

	start := time.Now()
	res := appleAlbumHintSync(canceledCtx, "PreCancelArtist", "PreCancelTitle", 250, nil)
	elapsed := time.Since(start)

	if res != "" {
		t.Errorf("expected empty string, got %q", res)
	}
	if elapsed > 50*time.Millisecond {
		t.Errorf("expected immediate return on pre-canceled context, took %v", elapsed)
	}

	// Clean up waitCh so background isn't leaked
	close(waitCh)
}

