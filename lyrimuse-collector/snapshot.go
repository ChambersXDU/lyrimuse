package main

import (
	_ "image/jpeg"
	_ "image/png"
	"time"
)

type snapshot struct {
	Title  string
	Artist string
	Album  string

	AlbumHint string
	Bundle    string
	Duration  float64
	Playing   bool

	Elapsed float64
	Rate    float64
	McTS    time.Time

	AnchorElapsed float64

	Position float64
	AnchorTS time.Time
}

func (s snapshot) key() string {
	if s.Title == "" && s.Artist == "" {
		return ""
	}
	return s.Title + "|" + s.Artist + "|" + s.Album
}

func (s snapshot) albumForUpload() string {
	if s.Album != "" {
		return s.Album
	}
	return s.AlbumHint
}

func extract(state map[string]any) snapshot {
	str := func(k string) string { v, _ := state[k].(string); return v }
	num := func(k string) float64 { v, _ := state[k].(float64); return v }
	playing, _ := state["playing"].(bool)
	mcTS := time.Now()
	if ts := str("timestamp"); ts != "" {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			mcTS = t
		}
	}

	duration := num("duration")
	return snapshot{
		Title:         str("title"),
		Artist:        str("artist"),
		Album:         str("album"),
		Bundle:        str("bundleIdentifier"),
		Duration:      duration,
		Playing:       playing,
		Elapsed:       num("elapsedTime"),
		Rate:          num("playbackRate"),
		McTS:          mcTS,
		AnchorElapsed: num("anchorElapsedTime"),
	}
}
