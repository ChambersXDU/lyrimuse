package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPlaybackEventsWakeAuthoritativePoll(t *testing.T) {
	for _, tc := range []struct {
		line string
		want bool
	}{
		{`{"type":"data","diff":true,"payload":{"title":"New song"}}`, true},
		{`{"type":"data","diff":true,"payload":{"playing":false}}`, true},
		{`{"type":"data","payload":{"artist":null}}`, true},
		{`{"type":"data","payload":{"elapsedTime":3}}`, false},
		{`{"type":"data","payload":{"artworkData":"bytes"}}`, false},
		{`{"type":"error","payload":{"title":"error"}}`, false},
		{`null`, false}, {`broken`, false},
	} {
		if got := playbackEventWakesPoll([]byte(tc.line)); got != tc.want {
			t.Errorf("%s: got %v", tc.line, got)
		}
	}
	wake := make(chan struct{}, 1)
	readPlaybackEvents(context.Background(), strings.NewReader(strings.Repeat(`{"type":"data","payload":{"title":"song"}}`+"\n", 100)), wake)
	if len(wake) != 1 {
		t.Fatalf("events should coalesce, got %d", len(wake))
	}
}

func TestLyricRoundFailureGetsOnePromptRetry(t *testing.T) {
	ctx, round := withLyricSourceRound(context.Background())
	noteLyricRoundFailure(ctx, "music.163.com", errors.New("timeout"), 0)
	noteLyricRoundFailure(ctx, "music.163.com", errors.New("timeout"), 0)
	noteLyricRoundFailure(ctx, "itunes.apple.com", errors.New("timeout"), 0)
	noteLyricRoundFailure(ctx, "c.y.qq.com", context.Canceled, 0)
	noteLyricRoundFailure(ctx, "lrclib.net", nil, 404)
	failed := round.failedSources()
	if len(failed) != 1 || failed[0] != "netease" {
		t.Fatalf("failed sources = %v", failed)
	}

	previous := lyricSourceBreakerShared
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	defer func() { lyricSourceBreakerShared = previous }()
	e := enrichEntry{TS: time.Now().Unix() - 31, LyricsSourcesFailed: failed}
	if !needsLyricsFirstFill(e) {
		t.Fatal("transport failure must retry in this playback, not tomorrow")
	}
	e.LyricsFillCount = 1
	if needsLyricsFirstFill(e) {
		t.Fatal("prompt retry must be bounded")
	}
	e.LyricsFillCount = 0
	e.ManualLyrics = true
	if needsLyricsFirstFill(e) {
		t.Fatal("manual edits must remain protected")
	}
	e.ManualLyrics = false
	e.Instrumental = true
	if needsLyricsFirstFill(e) {
		t.Fatal("instrumental result must remain protected")
	}
	freshCtx, fresh := withLyricSourceRound(context.Background())
	noteLyricRoundFailure(freshCtx, "lrclib.net", nil, 503)
	noteLyricRoundFailure(freshCtx, "c.y.qq.com", nil, 429)
	if len(fresh.failedSources()) != 2 {
		t.Fatal("server errors and throttling need recovery")
	}
	if len(round.failedSources()) != 1 {
		t.Fatal("failure records must be local to the search round")
	}
}

func TestPlaybackWatcherCancellation(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "stream")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nexec /bin/sleep 60\n"), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { watchPlaybackEvents(ctx, binary, make(chan struct{}, 1)); close(done) }()
	time.Sleep(30 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("stopping collector must close a silent stream")
	}
}
