package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	lyricsFillSweepInitialDelay    = 10 * time.Minute
	lyricsFillSweepInterval        = 24 * time.Hour
	lyricsFillSweepGap             = 15 * time.Second
	lyricsFillSweepDailyCap        = 40
	lyricsFillRequestCheckInterval = 2 * time.Second
)

var (
	lyricsFillRequestPath string
	lyricsFillStatusPath  string

	lyricsFillSweepMu      sync.Mutex
	lyricsFillSweepRunning bool
	lyricsFillSweepCancel  context.CancelFunc
)

type lyricsFillStatus struct {
	Running    bool   `json:"running"`
	Manual     bool   `json:"manual"`
	Total      int    `json:"total"`
	Done       int    `json:"done"`
	Filled     int    `json:"filled"`
	Current    string `json:"current,omitempty"`
	StartedAt  int64  `json:"startedAt"`
	UpdatedAt  int64  `json:"updatedAt"`
	FinishedAt int64  `json:"finishedAt,omitempty"`
	Cancelled  bool   `json:"cancelled,omitempty"`
}

func setLyricsFillPaths() {
	lyricsFillRequestPath = configFilePath(clientName + "-lyrics-fill-request.txt")
	lyricsFillStatusPath = configFilePath(clientName + "-lyrics-fill-status.json")
	_ = os.Remove(lyricsFillRequestPath)
	_ = os.Remove(lyricsFillStatusPath)
}

func startLyricsFillSweeper(ctx context.Context) {
	if lyricsFillRequestPath == "" {
		return
	}
	next := time.NewTimer(lyricsFillSweepInitialDelay)
	defer next.Stop()
	poll := time.NewTicker(lyricsFillRequestCheckInterval)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-next.C:
			go runLyricsFillSweep(ctx, lyricsFillRequest{})
			next.Reset(lyricsFillSweepInterval)
		case <-poll.C:
			if ctx.Err() != nil {
				return
			}
			req, ok := readLyricsFillRequest()
			if !ok {
				continue
			}
			if req.cancel {
				cancelLyricsFillSweep()
				continue
			}
			go runLyricsFillSweep(ctx, req)
		}
	}
}

type lyricsFillRequest struct {
	manual bool
	cancel bool
	all    bool
	keys   map[string]bool
}

func parseLyricsFillRequest(text string) lyricsFillRequest {
	req := lyricsFillRequest{manual: true}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "":
		case line == "all":
			req.all = true
		case line == "cancel":
			req.cancel = true
		default:
			if req.keys == nil {
				req.keys = map[string]bool{}
			}
			req.keys[line] = true
		}
	}
	return req
}

func readLyricsFillRequest() (lyricsFillRequest, bool) {
	if lyricsFillRequestPath == "" {
		return lyricsFillRequest{}, false
	}
	if _, err := os.Stat(lyricsFillRequestPath); err != nil {
		return lyricsFillRequest{}, false
	}
	data, err := os.ReadFile(lyricsFillRequestPath)
	if err != nil {
		return lyricsFillRequest{}, false
	}
	_ = os.Remove(lyricsFillRequestPath)
	req := parseLyricsFillRequest(string(data))
	if !req.all && !req.cancel && len(req.keys) == 0 {
		return lyricsFillRequest{}, false
	}
	return req, true
}

func lyricsFillSweepCandidates(req lyricsFillRequest) []string {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	var keys []string
	for key, e := range enrichCache {
		if req.keys != nil && !req.keys[key] {
			continue
		}
		if e.Lyrics != "" || e.ManualLyrics || e.Instrumental || enrichInflight[key] {
			continue
		}
		if !req.manual && !needsLyricsFirstFill(e) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !req.manual && len(keys) > lyricsFillSweepDailyCap {
		keys = keys[:lyricsFillSweepDailyCap]
	}
	return keys
}

func cancelLyricsFillSweep() {
	lyricsFillSweepMu.Lock()
	defer lyricsFillSweepMu.Unlock()
	if lyricsFillSweepRunning && lyricsFillSweepCancel != nil {
		lyricsFillSweepCancel()
	}
}

func runLyricsFillSweep(parent context.Context, req lyricsFillRequest) {
	lyricsFillSweepMu.Lock()
	if lyricsFillSweepRunning {
		lyricsFillSweepMu.Unlock()
		slog.Info("lyrics fill sweep: already running, ignoring new request", "manual", req.manual)
		return
	}
	ctx, cancel := context.WithCancel(parent)
	lyricsFillSweepRunning = true
	lyricsFillSweepCancel = cancel
	lyricsFillSweepMu.Unlock()
	defer func() {
		cancel()
		lyricsFillSweepMu.Lock()
		lyricsFillSweepRunning = false
		lyricsFillSweepCancel = nil
		lyricsFillSweepMu.Unlock()
	}()

	keys := lyricsFillSweepCandidates(req)
	status := lyricsFillStatus{Running: true, Manual: req.manual, Total: len(keys), StartedAt: time.Now().Unix()}
	writeLyricsFillStatus(status)
	slog.Info("lyrics fill sweep: start", "manual", req.manual, "candidates", len(keys))
	if len(keys) == 0 {
		status.Running = false
		status.FinishedAt = time.Now().Unix()
		writeLyricsFillStatus(status)
		return
	}
	for i, key := range keys {
		if i > 0 {
			select {
			case <-ctx.Done():
			case <-time.After(lyricsFillSweepGap):
			}
		}
		if ctx.Err() != nil {
			status.Cancelled = true
			break
		}
		status.Current = key
		writeLyricsFillStatus(status)
		if lyricsFillSweepOne(key) {
			status.Filled++
		}
		status.Done++
		status.Current = ""
		writeLyricsFillStatus(status)
	}
	status.Running = false
	status.Current = ""
	status.FinishedAt = time.Now().Unix()
	writeLyricsFillStatus(status)
	slog.Info("lyrics fill sweep: done", "manual", req.manual, "total", status.Total, "done", status.Done, "filled", status.Filled, "cancelled", status.Cancelled)
}

func lyricsFillSweepOne(key string) bool {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	before, ok := enrichCache[key]
	if !ok || before.Lyrics != "" || before.ManualLyrics || before.Instrumental || enrichInflight[key] {
		enrichMu.Unlock()
		return false
	}
	dur := before.ResolvedDurationSecs
	if dur <= 0 {
		dur = before.DurationSecs
	}
	enrichInflight[key] = true
	enrichMu.Unlock()

	retryLyricsUpgrade(context.Background(), key, artist, title, album, dur, true)
	enrichMu.Lock()
	after := enrichCache[key]
	enrichMu.Unlock()
	return after.Lyrics != "" || after.Instrumental || (after.PlainLyrics != "" && before.PlainLyrics == "")
}

func writeLyricsFillStatus(s lyricsFillStatus) {
	if lyricsFillStatusPath == "" {
		return
	}
	s.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	if err := os.WriteFile(lyricsFillStatusPath, data, 0o644); err != nil {
		slog.Warn("lyrics fill sweep: status write failed", "err", err)
	}
}
