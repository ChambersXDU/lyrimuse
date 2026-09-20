package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestResolveLastfmExcludedBundles(t *testing.T) {
	got := resolveLastfmExcludedBundles([]string{" com.tencent.QQMusicMac ", "", "com.apple.Safari", "com.apple.Safari"})
	if len(got) != 2 || !got["com.tencent.QQMusicMac"] || !got["com.apple.Safari"] {
		t.Fatalf("resolve: got %v", got)
	}
	if m := resolveLastfmExcludedBundles(nil); m == nil || len(m) != 0 {
		t.Fatalf("nil input should resolve to an empty (non-nil) map, got %v", m)
	}
}

func TestLastfmExcluded(t *testing.T) {
	saved, savedPath := features, lastfmExcludePath
	defer func() {
		features = saved
		setLastfmExcludePath(savedPath)
	}()

	setLastfmExcludePath("")

	features.LastfmExcludedBundles = map[string]bool{}
	if lastfmExcluded(qqMusicBundleID) {
		t.Fatal("empty exclusion set must exclude nothing")
	}

	features.LastfmExcludedBundles = resolveLastfmExcludedBundles([]string{qqMusicBundleID, "com.apple.Safari"})
	cases := []struct {
		bundle string
		want   bool
	}{
		{qqMusicBundleID, true},
		{spotifyBundleID, false},
		{appleMusicBundleID, false},

		{"com.apple.WebKit.GPU", true},
		{"com.apple.Safari", true},
		{"company.thebrowser.Browser", false},
		{"", false},
	}
	for _, c := range cases {
		if got := lastfmExcluded(c.bundle); got != c.want {
			t.Errorf("lastfmExcluded(%q) = %v, want %v", c.bundle, got, c.want)
		}
	}
}

func TestLastfmExcludedHotReloadsFromFile(t *testing.T) {
	savedPath, savedFeatures := lastfmExcludePath, features
	defer func() {
		setLastfmExcludePath(savedPath)
		features = savedFeatures
	}()

	features.LastfmExcludedBundles = nil

	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse-features.json")
	write := func(body string, mtime time.Time) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}
	base := time.Now().Add(-time.Hour)

	setLastfmExcludePath(path)
	if lastfmExcluded(qqMusicBundleID) {
		t.Fatal("missing features.json must exclude nothing")
	}

	write(`{"lastfm_excluded_bundles":["`+qqMusicBundleID+`","com.apple.Safari"]}`, base)
	if !lastfmExcluded(qqMusicBundleID) {
		t.Fatal("QQ should be excluded after the file appears — no restart involved")
	}
	if !lastfmExcluded("com.apple.WebKit.GPU") {
		t.Fatal("Safari's media proxy must fold onto com.apple.Safari")
	}
	if lastfmExcluded(spotifyBundleID) {
		t.Fatal("Spotify is not in the list")
	}

	write(`{"lastfm_excluded_bundles":["com.apple.Safari"]}`, base.Add(time.Minute))
	if lastfmExcluded(qqMusicBundleID) {
		t.Fatal("QQ should be back in after the rewrite (hot reload failed)")
	}
	if !lastfmExcluded("com.apple.Safari") {
		t.Fatal("Safari should still be excluded")
	}

	write(`{"players":["apple_music"]}`, base.Add(2*time.Minute))
	if lastfmExcluded("com.apple.Safari") {
		t.Fatal("dropping the key must clear every exclusion")
	}

	write(`{ not json`, base.Add(3*time.Minute))
	if lastfmExcluded(qqMusicBundleID) || lastfmExcluded("com.apple.Safari") {
		t.Fatal("an unparseable features.json must fail open")
	}

	setLastfmExcludePath("")
	features.LastfmExcludedBundles = resolveLastfmExcludedBundles([]string{spotifyBundleID})
	if !lastfmExcluded(spotifyBundleID) {
		t.Fatal("with no path registered the startup-parsed set should be used")
	}
}
