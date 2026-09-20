package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

var lastfmFeedPath string

const feedHeartbeat = 60 * time.Second

const (
	feedIntervalActive = 15 * time.Second
	feedIntervalIdle   = 60 * time.Second
	feedActivityWindow = 10 * time.Minute
)

func lastfmFeedInterval(localPlaying bool, lastActivity, now time.Time) time.Duration {
	if localPlaying {
		return feedIntervalActive
	}
	if !lastActivity.IsZero() && now.Sub(lastActivity) < feedActivityWindow {
		return feedIntervalActive
	}
	return feedIntervalIdle
}

func lastfmFeedActivityAt(page lastfmRecentPage, fetchedAt time.Time) time.Time {
	if page.NowPlaying != nil {
		return fetchedAt
	}
	if len(page.Done) > 0 && page.Done[0].UTS > 0 {
		return time.Unix(page.Done[0].UTS, 0)
	}
	return time.Time{}
}

var lastfmFeedNudgeAt atomic.Int64

const backfillFeedNudgeDelay = 5 * time.Second

func requestLastfmFeedRefresh(after time.Duration) {
	target := time.Now().Add(after).UnixNano()
	for {
		cur := lastfmFeedNudgeAt.Load()
		if cur != 0 && cur <= target {
			return
		}
		if lastfmFeedNudgeAt.CompareAndSwap(cur, target) {
			return
		}
	}
}

func lastfmFeedNudgeDue(now time.Time) bool {
	t := lastfmFeedNudgeAt.Load()
	if t == 0 || now.UnixNano() < t {
		return false
	}
	return lastfmFeedNudgeAt.CompareAndSwap(t, 0)
}

var lastfmFeedNudgePath string

func touchLastfmFeedNudgeFile() {
	if lastfmFeedNudgePath == "" {
		return
	}
	if err := os.WriteFile(lastfmFeedNudgePath, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o644); err != nil {
		log.Printf("lastfm feed nudge: write %s: %v", lastfmFeedNudgePath, err)
	}
}

func lastfmFeedNudgeFileDue() bool {
	if lastfmFeedNudgePath == "" {
		return false
	}
	if _, err := os.Stat(lastfmFeedNudgePath); err != nil {
		return false
	}
	if err := os.Remove(lastfmFeedNudgePath); err != nil {
		log.Printf("lastfm feed nudge: remove %s: %v", lastfmFeedNudgePath, err)
	}
	return true
}

type lastfmFeedTrack struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
	Album  string `json:"album,omitempty"`
	Image  string `json:"image,omitempty"`
	UTS    int64  `json:"uts,omitempty"`
}

type lastfmFeedFile struct {
	Username   string            `json:"username"`
	FetchedAt  int64             `json:"fetchedAt"`
	Total      int               `json:"total"`
	NowPlaying *lastfmFeedTrack  `json:"nowPlaying,omitempty"`
	Tracks     []lastfmFeedTrack `json:"tracks"`
}

func feedTrack(t lastfmTrack) lastfmFeedTrack {
	return lastfmFeedTrack{Artist: t.Artist, Title: t.Title, Album: t.Album, Image: t.Image, UTS: t.UTS}
}

func lastfmFeedContentKey(page lastfmRecentPage) string {
	var b strings.Builder
	b.WriteString(strconv.Itoa(page.Total))
	b.WriteByte('|')
	if page.NowPlaying != nil {
		b.WriteString(page.NowPlaying.Artist)
		b.WriteByte(0x1f)
		b.WriteString(page.NowPlaying.Title)
	}
	for _, t := range page.Done {
		b.WriteByte('|')
		b.WriteString(strconv.FormatInt(t.UTS, 10))
	}
	return b.String()
}

func shouldWriteLastfmFeed(prevKey, curKey string, lastWrite, now time.Time) bool {
	if curKey != prevKey {
		return true
	}
	return lastWrite.IsZero() || now.Sub(lastWrite) >= feedHeartbeat
}

var (
	lastfmFeedLastKey   string
	lastfmFeedLastWrite time.Time
)

func writeLastfmRecentFeed(user string, page lastfmRecentPage, fetchedAt time.Time) {
	if lastfmFeedPath == "" || user == "" {
		return
	}
	key := lastfmFeedContentKey(page)
	if !shouldWriteLastfmFeed(lastfmFeedLastKey, key, lastfmFeedLastWrite, fetchedAt) {
		return
	}
	f := lastfmFeedFile{
		Username:  user,
		FetchedAt: fetchedAt.Unix(),
		Total:     page.Total,
		Tracks:    make([]lastfmFeedTrack, 0, len(page.Done)),
	}
	if page.NowPlaying != nil {
		np := feedTrack(*page.NowPlaying)
		f.NowPlaying = &np
	}
	for _, t := range page.Done {
		f.Tracks = append(f.Tracks, feedTrack(t))
	}
	data, err := json.Marshal(f)
	if err != nil {
		return
	}

	tmp := filepath.Join(filepath.Dir(lastfmFeedPath), "."+filepath.Base(lastfmFeedPath)+".tmp")
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("lastfm feed: write temp failed: %v", err)
		return
	}
	if err := os.Rename(tmp, lastfmFeedPath); err != nil {
		log.Printf("lastfm feed: rename failed: %v", err)
		os.Remove(tmp)
		return
	}
	lastfmFeedLastKey = key
	lastfmFeedLastWrite = fetchedAt
}
