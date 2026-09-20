package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"time"
)

const appleMusicBundleID = "com.apple.Music"

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
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", getStateScript).Output()
	if err != nil {
		return nil, false
	}
	if strings.TrimSpace(string(out)) == "null" {
		return map[string]any{}, true
	}
	var state map[string]any
	if err := json.Unmarshal(out, &state); err != nil {
		return nil, false
	}
	for _, key := range []string{"title", "artist", "album"} {
		if value, ok := state[key].(string); ok {
			state[key] = cleanMediaTag(value)
		}
	}
	state["bundleIdentifier"] = appleMusicBundleID
	return state, true
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
