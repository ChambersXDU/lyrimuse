package main

import "strings"

var spotifyTrackIDHints = map[string]string{}

const spotifyTrackIDHintCap = 512

func spotifyTrackIDFromURI(uri string) string {
	const prefix = "spotify:track:"
	u := strings.TrimSpace(uri)
	if !strings.HasPrefix(u, prefix) {
		return ""
	}
	id := u[len(prefix):]
	if len(id) != 22 {
		return ""
	}
	for _, r := range id {
		isDigit := r >= '0' && r <= '9'
		isLower := r >= 'a' && r <= 'z'
		isUpper := r >= 'A' && r <= 'Z'
		if !isDigit && !isLower && !isUpper {
			return ""
		}
	}
	return id
}

func spotifyURIIsAd(uri string) bool {
	return strings.HasPrefix(strings.TrimSpace(uri), "spotify:ad")
}

func spotifyTrackURL(id string) string {
	if id == "" {
		return ""
	}
	return "https://open.spotify.com/track/" + id
}

func (e enrichEntry) spotifyLink() string {
	if u := spotifyTrackURL(e.SpotifyTrackID); u != "" {
		return u
	}
	return e.SpotifyURL
}

func noteSpotifyTrackID(artist, title, album, id string) {
	if id == "" || title == "" {
		return
	}
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if len(spotifyTrackIDHints) >= spotifyTrackIDHintCap {
		spotifyTrackIDHints = map[string]string{}
	}
	spotifyTrackIDHints[key] = id
}

func applySpotifyTrackIDHintLocked(key string, e *enrichEntry) bool {
	id := spotifyTrackIDHints[key]
	if id == "" || e.SpotifyTrackID == id {
		return false
	}
	e.SpotifyTrackID = id
	return true
}

func spotifyListenFields(bundleID, trackID string) map[string]string {
	if bundleID != spotifyBundleID || trackID == "" {
		return nil
	}
	u := spotifyTrackURL(trackID)
	return map[string]string{
		"spotify_id":    u,
		"origin_url":    u,
		"music_service": "spotify.com",
	}
}
