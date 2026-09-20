package main

import "testing"

func TestLyricsFileSuffixOfPicksLongestMatch(t *testing.T) {
	cases := []struct{ name, want string }{
		{"Artist - Title - Album.lrc", ".lrc"},
		{"Artist - Title - Album.tr.lrc", ".tr.lrc"},
		{"Artist - Title - Album.roma.lrc", ".roma.lrc"},
		{"Artist - Title - Album.yrc", ".yrc"},

		{"Artist - Title - Album~1a2b3c.tr.lrc", ".tr.lrc"},

		{".DS_Store", ""},
		{"cover.jpg", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := lyricsFileSuffixOf(c.name); got != c.want {
			t.Errorf("lyricsFileSuffixOf(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestLyricsFileVariantsShareOneGroup(t *testing.T) {
	const base = "Michael Jackson - Blue Gangsta - XSCAPE (Deluxe)"
	for _, suffix := range lyricsFileSuffixes {
		name := base + suffix
		got := lyricsFileSuffixOf(name)
		if got != suffix {
			t.Fatalf("lyricsFileSuffixOf(%q) = %q, want %q", name, got, suffix)
		}
		if trimmed := name[:len(name)-len(got)]; trimmed != base {
			t.Errorf("%q 去掉后缀后是 %q, want %q", name, trimmed, base)
		}
	}
}
