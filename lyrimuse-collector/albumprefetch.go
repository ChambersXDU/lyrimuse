package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const albumPrefetchMaxTracks = 30

const albumPrefetchStagger = 3 * time.Second

var (
	prefetchMu     sync.Mutex
	lastPrefetched string
)

func prefetchAlbumSiblings(ctx context.Context, currentArtist, currentTitle, album, bundleID string) {
	if ctx == nil {
		ctx = context.Background()
	}
	if album == "" {
		return
	}
	prefetchMu.Lock()
	if lastPrefetched == album {
		prefetchMu.Unlock()
		return
	}
	lastPrefetched = album
	prefetchMu.Unlock()

	go func() {
		tracks, ok := albumTracks(currentArtist, currentTitle, album, bundleID)
		if !ok {
			return
		}
		if len(tracks) > albumPrefetchMaxTracks {
			log.Printf("album prefetch: skipping %q (%d tracks, over the %d-track safety cap)", album, len(tracks), albumPrefetchMaxTracks)
			return
		}
		queued := 0

		currentLoose := loosenEnrichKey(enrichKey(currentArtist, currentTitle, album))
		for _, t := range tracks {
			if t.title == "" || loosenEnrichKey(enrichKey(t.artist, t.title, album)) == currentLoose {
				continue
			}

			key := enrichKey(t.artist, t.title, album)
			enrichMu.Lock()
			_, exists := enrichCache[key]
			if !exists {

				if _, found := canonicalEnrichKey(key); found {
					exists = true
				}
			}

			_, inflight := looseInflightKey(key)
			eligible := !exists && !inflight
			if eligible {
				enrichInflight[key] = true
			}
			enrichMu.Unlock()
			if !eligible {
				continue
			}
			if queued > 0 {

				select {
				case <-time.After(albumPrefetchStagger):
				case <-ctx.Done():
					return
				}
			}
			queued++

			go resolveEnrichAsync(ctx, key, t.artist, t.title, album, t.duration)
		}

		log.Printf("album prefetch: %q → %d tracks, %d queued", album, len(tracks), queued)
	}()
}

type albumTrack struct {
	title, artist string
	duration      float64

	neteaseSongID int64
	neteaseAlbum  string
}

func albumTracks(artist, title, album, bundleID string) ([]albumTrack, bool) {
	if bundleID == appleMusicBundleID {
		return albumTracksFromMusicApp(album)
	}

	ne := neteaseLookup(context.Background(), artist, title, album, 0)
	if ne.AlbumID <= 0 {
		return nil, false
	}

	if albumScore(ne.Album, album) < 100 {
		log.Printf("album prefetch: netease album %q != local %q, skipping", ne.Album, album)
		return nil, false
	}
	return neteaseAlbumTracks(ne.AlbumID)
}

func albumTracksFromMusicApp(album string) ([]albumTrack, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	script := fmt.Sprintf(`if application "Music" is not running then
	return ""
end if
tell application "Music"
	set output to ""
	repeat with t in (every track of library playlist 1 whose album is %s and media kind is song)
		set output to output & (name of t) & tab & (artist of t) & tab & (duration of t) & linefeed
	end repeat
	return output
end tell`, appleScriptQuote(album))
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return nil, false
	}
	var tracks []albumTrack
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		dur, _ := strconv.ParseFloat(strings.TrimSpace(parts[2]), 64)
		tracks = append(tracks, albumTrack{title: parts[0], artist: parts[1], duration: dur})
	}
	return tracks, true
}

func appleScriptQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
