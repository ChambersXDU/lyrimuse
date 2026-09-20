package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

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

	time.Sleep(50 * time.Millisecond)

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

	appleAlbumHintMu.Lock()
	defer appleAlbumHintMu.Unlock()
	if appleAlbumHintInflight[key] {
		t.Errorf("expected inflight to be false after completion")
	}
	if _, exists := appleAlbumHintWaiters[key]; exists {
		t.Errorf("expected waiter channel to be removed from map after completion")
	}
}

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

	for i := 0; i < persistentCount; i++ {
		wg.Add(1)
		idx := i
		ctx := context.Background()
		go func() {
			defer wg.Done()
			persistentResults[idx] = appleAlbumHintSync(ctx, "CancelArtist", "CancelTitle", 210, nil)
		}()
	}

	time.Sleep(60 * time.Millisecond)

	expectedAlbum := "ValidAlbumForPersistent"
	cands := []albumHintCandidate{
		{Artist: "CancelArtist", Album: expectedAlbum},
	}
	storeAppleAlbumHintResult(key, cands, true)

	wg.Wait()

	for i, res := range canceledResults {
		if res != "" {
			t.Errorf("canceled waiter %d expected empty string, got %q", i, res)
		}
	}

	for i, res := range persistentResults {
		if res != expectedAlbum {
			t.Errorf("persistent waiter %d expected %q, got %q", i, expectedAlbum, res)
		}
	}
}

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

	appleAlbumHintMu.Lock()
	appleAlbumHintInflight[key] = true
	waitCh := make(chan struct{})
	appleAlbumHintWaiters[key] = waitCh
	appleAlbumHintMu.Unlock()

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

	close(waitCh)
}
