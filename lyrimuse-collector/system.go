package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const getStateScript = `(() => {
    const Music = Application("Music");
    try {
        if (!Music.running()) return JSON.stringify(null);
    } catch (e) {
        return JSON.stringify(null);
    }
    let state;
    try {
        state = Music.playerState();
    } catch (e) {
        return JSON.stringify(null);
    }
    if (state === "stopped") return JSON.stringify(null);
    let track;
    try {
        track = Music.currentTrack;
        if (!track.exists()) return JSON.stringify(null);
    } catch (e) {
        return JSON.stringify(null);
    }
    try {
        return JSON.stringify({
            title: track.name(),
            artist: track.artist(),
            album: track.album(),
            duration: track.duration(),
            elapsedTime: Music.playerPosition(),
            playing: state === "playing",
            playbackRate: state === "playing" ? 1 : 0,
            isMusicApp: true,
            bundleIdentifier: "com.apple.Music"
        });
    } catch (e) {
        return JSON.stringify(null);
    }
})()`

func getState(ctx context.Context) (map[string]any, bool) {
	if len(features.Players) == 1 && features.Players[playerAppleMusic] {
		return getAppleMusicOnlyState(ctx)
	}
	var state map[string]any
	var ok bool
	if features.Players[playerAuto] {
		state, ok = getAutoDetectedState(ctx)
	} else {
		state, ok = getMultiSelectedState(ctx)
	}
	return selectAppleMusicFallback(state, ok, features.Players[playerAuto] || features.Players[playerAppleMusic], func() (map[string]any, bool) {
		return getAppleMusicOnlyState(ctx)
	})
}

// Keep accepted native players; a browser's global focus must not obscure Music.app.
func selectAppleMusicFallback(state map[string]any, ok, allowed bool, fetch func() (map[string]any, bool)) (map[string]any, bool) {
	bundle, _ := state["bundleIdentifier"].(string)
	if !allowed || isKnownPlayerBundleID(bundle) {
		return state, ok
	}
	music, musicOK := fetch()
	if !musicOK || len(music) == 0 {
		return state, ok
	}
	playing, _ := music["playing"].(bool)
	if len(state) == 0 || playing {
		return music, true
	}
	return state, ok
}

func getAppleMusicOnlyState(ctx context.Context) (map[string]any, bool) {
	state, ok := getAppleMusicState(ctx)

	if !ok || len(state) == 0 {
		return state, ok
	}
	raw, bundleID, rawOK := fetchRawMediaControlState(ctx)
	if !rawOK || bundleID != appleMusicBundleID {

		return state, true
	}
	mergeRadioKeys(state, raw)
	return state, true
}

func mergeRadioKeys(state, raw map[string]any) {
	hash, _ := raw["radioStationHash"].(string)
	if hash == "" {
		return
	}
	state["radioStationHash"] = hash

	if d, ok := raw["catalogDurationSecs"].(float64); ok && d > 0 {
		state["catalogDurationSecs"] = d
	}
}

func getAppleMusicState(ctx context.Context) (map[string]any, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", getStateScript).Output()
	if err != nil {

		return nil, false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "null" {

		return map[string]any{}, true
	}
	var state map[string]any
	if err := json.Unmarshal(out, &state); err != nil {
		return nil, false
	}

	for _, k := range []string{"title", "artist", "album"} {
		if v, ok := state[k].(string); ok {
			state[k] = cleanMediaTag(v)
		}
	}
	return state, true
}

func appleMusicPosition(ctx context.Context) (float64, bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	const script = `tell application "Music"
	if player state is playing then return (player position as text)
	return "x"
end tell`
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return 0, false
	}
	p, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || p < 0 {
		return 0, false
	}
	return p, true
}

const (
	appleMusicBundleID   = "com.apple.Music"
	qqMusicBundleID      = "com.tencent.QQMusicMac"
	neteaseMusicBundleID = "com.netease.163music"
	spotifyBundleID      = "com.spotify.client"
	kugouMusicBundleID   = "com.kugou.mac.Music"
)

func playerBundleID(player string) string {
	switch player {
	case playerQQMusic:
		return qqMusicBundleID
	case playerNetease:
		return neteaseMusicBundleID
	case playerSpotify:
		return spotifyBundleID
	case playerKugou:
		return kugouMusicBundleID
	default:
		return appleMusicBundleID
	}
}

func spotifyCurrentTrackURI(ctx context.Context) (uri string, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`if application "Spotify" is running then tell application "Spotify" to spotify url of current track`).Output()
	if err != nil {
		return "", false
	}
	uri = strings.TrimSpace(string(out))
	return uri, uri != ""
}

func isAdBreak(bundleID, artist, title, album string) bool {
	if bundleID != spotifyBundleID {
		return false
	}
	return album == "" || artist == "" || title == "—"
}

func isKnownPlayerBundleID(bundleID string) bool {
	switch bundleID {
	case "com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID:
		return true
	default:
		return false
	}
}

func trustedPlaybackNotASong(bundleID, artist, album string) bool {
	if isKnownPlayerBundleID(bundleID) {
		return false
	}
	if !isTrustedPlayerBundleID(bundleID) {
		return false
	}
	return strings.TrimSpace(artist) == "" || strings.TrimSpace(album) == ""
}

func isAcceptedPlayerBundleID(bundleID string) bool {
	return isKnownPlayerBundleID(bundleID) || isTrustedPlayerBundleID(bundleID)
}

func isTrustedPlayerBundleID(bundleID string) bool {
	if _, trusted := features.TrustedPlayers[bundleID]; trusted {
		return true
	}
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		_, trusted := features.TrustedPlayers[owner]
		return trusted
	}
	return false
}

var mediaProxyOwners = map[string]string{
	"com.apple.WebKit.GPU": "com.apple.Safari",
}

const mediaPlayerLabelIPhone = "Apple Music (iOS)"

func mediaPlayerLabel(bundleID string) string {
	switch bundleID {
	case qqMusicBundleID:
		return "QQ Music (macOS)"
	case neteaseMusicBundleID:
		return "NetEase Cloud Music (macOS)"
	case spotifyBundleID:
		return "Spotify (macOS)"
	case kugouMusicBundleID:
		return "KuGou Music (macOS)"
	default:
		lookupID := bundleID
		if owner, ok := mediaProxyOwners[bundleID]; ok {
			lookupID = owner
		}
		if name, trusted := features.TrustedPlayers[lookupID]; trusted {
			if name != "" {
				return name + " (macOS)"
			}
			return lookupID + " (macOS)"
		}
		return "Apple Music (macOS)"
	}
}

func cleanMediaTag(s string) string {
	if s == "" {
		return ""
	}
	s = strings.Map(func(r rune) rune {
		switch r {
		case '\u00a0', '\u2007', '\u202f', '\u3000':
			return ' '
		case '\u200b', '\u200c', '\u200d', '\ufeff':
			return -1
		}
		return r
	}, s)

	return strings.Join(strings.Fields(s), " ")
}

type mediaControlRawState struct {
	Title          string  `json:"title"`
	Artist         string  `json:"artist"`
	Album          string  `json:"album"`
	BundleID       string  `json:"bundleIdentifier"`
	Duration       float64 `json:"duration"`
	ElapsedTime    float64 `json:"elapsedTime"`
	ElapsedTimeNow float64 `json:"elapsedTimeNow"`
	Playing        bool    `json:"playing"`

	Timestamp    string  `json:"timestamp"`
	PlaybackRate float64 `json:"playbackRate"`

	TrackNumber int `json:"trackNumber"`

	UniqueIdentifier int64 `json:"uniqueIdentifier"`

	RadioStationHash string `json:"radioStationHash"`

	ArtworkData     string `json:"artworkData"`
	ArtworkMimeType string `json:"artworkMimeType"`
}

func getQQMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, qqMusicBundleID)
}

func getNeteaseMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, neteaseMusicBundleID)
}

func getSpotifyState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, spotifyBundleID)
}

func getKugouMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, kugouMusicBundleID)
}

func matchMediaControlState(ctx context.Context, expectedBundleID string) (map[string]any, bool) {
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if bundleID != expectedBundleID {

		return map[string]any{}, true
	}
	return raw, true
}

func getAutoDetectedState(ctx context.Context) (map[string]any, bool) {
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if bundleID == appleMusicBundleID {
		return refineAppleMusicState(ctx, raw), true
	}
	switch bundleID {
	case qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID:
		return raw, true
	default:

		if isTrustedPlayerBundleID(bundleID) {
			artist, _ := raw["artist"].(string)
			album, _ := raw["album"].(string)
			title, _ := raw["title"].(string)

			rejected, patchAlbum := trustedPlaybackRejected(ctx, bundleID, artist, album, title)
			if rejected {
				return map[string]any{}, true
			}

			if patchAlbum != "" {
				raw["album"] = patchAlbum
			}
			return raw, true
		}

		return map[string]any{}, true
	}
}

func refineAppleMusicState(ctx context.Context, raw map[string]any) map[string]any {
	if state, ok := getAppleMusicState(ctx); ok && len(state) > 0 {

		mergeRadioKeys(state, raw)
		return state
	}
	return raw
}

func getMultiSelectedState(ctx context.Context) (map[string]any, bool) {
	accepted := map[string]bool{}
	for p := range features.Players {
		accepted[playerBundleID(p)] = true
	}
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if !accepted[bundleID] {
		if !isTrustedPlayerBundleID(bundleID) {

			return map[string]any{}, true
		}

		artist, _ := raw["artist"].(string)
		album, _ := raw["album"].(string)
		title, _ := raw["title"].(string)

		rejected, patchAlbum := trustedPlaybackRejected(ctx, bundleID, artist, album, title)
		if rejected {
			return map[string]any{}, true
		}

		if patchAlbum != "" {
			raw["album"] = patchAlbum
		}
	}
	if bundleID == appleMusicBundleID {
		return refineAppleMusicState(ctx, raw), true
	}
	return raw, true
}

func fetchRawMediaControlState(ctx context.Context) (map[string]any, string, bool) {
	bin := mediaControlBinaryPath()
	if bin == "" {
		return nil, "", false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "get", "--now", "--no-artwork").Output()
	if err != nil {
		return nil, "", false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "null" {

		return map[string]any{}, "", true
	}
	var raw mediaControlRawState
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, "", false
	}

	trackKey := raw.Artist + "|" + raw.Title
	elapsed := raw.ElapsedTime
	if raw.Playing {

		now := time.Now()
		anchorTS, republished := resolvePlayingAnchorTS(trackKey, raw.ElapsedTime, raw.Timestamp, raw.Duration, now)
		rate := raw.PlaybackRate
		if republished {
			rate = 0
		}
		elapsed = playingPositionSecs(raw.ElapsedTime, raw.ElapsedTimeNow, rate, anchorTS, now)

		if bias, ok := currentPositionBias(raw.Artist, raw.Title, raw.BundleID, raw.ElapsedTime, anchorTS, now); ok {
			elapsed -= bias
		}
		rememberPlayingPosition(trackKey, elapsed)
	} else {
		age, hasAge := mediaControlAnchorAge(raw.Timestamp, time.Now())
		last, hasLast := rememberedPlayingPosition(trackKey)
		elapsed = pausedPositionSecs(raw.ElapsedTime, age, hasAge, last, hasLast)
	}

	title, artistTag, album := cleanMediaTag(raw.Title), cleanMediaTag(raw.Artist), cleanMediaTag(raw.Album)

	duration := raw.Duration

	catalogDuration := 0.0
	if anchor, ok := appleCatalogAnchor(raw.BundleID, raw.UniqueIdentifier, raw.TrackNumber, title, album); ok && anchor.DurationSecs > 0 {
		if math.Abs(anchor.DurationSecs-duration) > appleCatalogDurationLogThreshold {
			log.Printf("apple catalog anchor overrode duration for %q: media-control %.3fs -> catalog %.3fs (track id %d)",
				title, duration, anchor.DurationSecs, raw.UniqueIdentifier)
		}
		duration = anchor.DurationSecs
		catalogDuration = anchor.DurationSecs
	}
	return map[string]any{
		"title": title, "artist": artistTag, "album": album,
		"duration": duration, "elapsedTime": elapsed,

		"anchorElapsedTime": raw.ElapsedTime,
		"playing":           raw.Playing, "playbackRate": raw.PlaybackRate,
		"isMusicApp": true, "bundleIdentifier": raw.BundleID,

		"radioStationHash": raw.RadioStationHash,

		"catalogDurationSecs": catalogDuration,
	}, raw.BundleID, true
}

func fetchNowPlayingArtwork(ctx context.Context, expectedBundleID, expectedArtist, expectedTitle string) (data []byte, mimeType string, ok bool) {
	bin := mediaControlBinaryPath()
	if bin == "" {
		return nil, "", false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "get", "--now").Output()
	if err != nil {
		return nil, "", false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" || trimmed == "null" {
		return nil, "", false
	}
	var raw mediaControlRawState
	if err := json.Unmarshal(out, &raw); err != nil || raw.ArtworkData == "" {
		return nil, "", false
	}
	if raw.BundleID != expectedBundleID ||
		cleanMediaTag(raw.Artist) != expectedArtist || cleanMediaTag(raw.Title) != expectedTitle {
		return nil, "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(raw.ArtworkData)
	if err != nil || len(decoded) == 0 {
		return nil, "", false
	}
	return decoded, raw.ArtworkMimeType, true
}

func mediaControlBinaryPath() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	bin := filepath.Join(filepath.Dir(exe), "media-control", "bin", "media-control")
	if _, err := os.Stat(bin); err != nil {
		log.Printf("media-control binary not found at %s: %v", bin, err)
		return ""
	}
	return bin
}
