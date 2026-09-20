package main

import "testing"

func TestAppleMusicFallbackIgnoresBrowserFocus(t *testing.T) {
	music := map[string]any{"bundleIdentifier": appleMusicBundleID, "playing": true, "title": "Song"}
	paused := map[string]any{"bundleIdentifier": appleMusicBundleID, "playing": false, "title": "Song"}
	browser := map[string]any{"bundleIdentifier": "com.google.Chrome", "playing": true}
	spotify := map[string]any{"bundleIdentifier": spotifyBundleID, "playing": true}
	for _, tc := range []struct {
		name        string
		system      map[string]any
		ok, allowed bool
		music       map[string]any
		want        string
		query       bool
	}{
		{"video rejected", map[string]any{}, true, true, music, appleMusicBundleID, true},
		{"system unavailable", nil, false, true, music, appleMusicBundleID, true},
		{"music paused after video", nil, true, true, paused, appleMusicBundleID, true},
		{"browser with music playing", browser, true, true, music, appleMusicBundleID, true},
		{"web music with native paused", browser, true, true, paused, "com.google.Chrome", true},
		{"other native music", spotify, true, true, music, spotifyBundleID, false},
		{"apple excluded", nil, true, false, music, "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			queried := false
			got, ok := selectAppleMusicFallback(tc.system, tc.ok, tc.allowed, func() (map[string]any, bool) { queried = true; return tc.music, true })
			id, _ := got["bundleIdentifier"].(string)
			if id != tc.want || !ok || queried != tc.query {
				t.Fatalf("got %v ok=%v query=%v", got, ok, queried)
			}
		})
	}
	got, ok := selectAppleMusicFallback(browser, true, true, func() (map[string]any, bool) { return nil, false })
	if !ok || got["bundleIdentifier"] != "com.google.Chrome" {
		t.Fatal("permission failure must preserve accepted web music")
	}
}
