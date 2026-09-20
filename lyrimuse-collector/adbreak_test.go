package main

import "testing"

func TestIsAdBreak(t *testing.T) {
	cases := []struct {
		name, bundle, artist, title, album string
		want                               bool
	}{

		{"Spotify 广告(无专辑)", spotifyBundleID, "Häagen-Dazs", "Take your sweet time.", "", true},
		{"Spotify 正常曲目", spotifyBundleID, "Michael Jackson", "Bad", "Bad", false},

		{"Spotify 广告(artist 空)", spotifyBundleID, "", "—", "SomeBrand", true},
		{"Spotify 广告(占位标题—)", spotifyBundleID, "Brand", "—", "Brand", true},

		{"Apple Music 无专辑不算广告", "com.apple.Music", "A", "T", "", false},
		{"QQ 音乐无专辑不算广告", qqMusicBundleID, "A", "T", "", false},
		{"网易云无专辑不算广告", neteaseMusicBundleID, "A", "T", "", false},
		{"空 bundle 不算广告", "", "", "", "", false},
	}
	for _, c := range cases {
		if got := isAdBreak(c.bundle, c.artist, c.title, c.album); got != c.want {
			t.Errorf("%s: isAdBreak(%q, %q, %q, %q) = %v, want %v",
				c.name, c.bundle, c.artist, c.title, c.album, got, c.want)
		}
	}
}
