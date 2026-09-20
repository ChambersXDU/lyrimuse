package main

import (
	neturl "net/url"
	"testing"
)

func TestLastfmEscape(t *testing.T) {
	cases := []struct{ in, want string }{

		{"夜曲+窃爱 (Live)", "%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29"},
		{"+44", "%252B44"},
		{"100%", "100%2525"},
		{"a+b%c", "a%252Bb%2525c"},

		{"开不了口 (live)", "%E5%BC%80%E4%B8%8D%E4%BA%86%E5%8F%A3%20%28live%29"},
		{"Beyond", "Beyond"},
		{"a b", "a%20b"},
	}
	for _, c := range cases {
		if got := lastfmEscape(c.in); got != c.want {
			t.Errorf("lastfmEscape(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLastfmGetQuerySortsAndEscapes(t *testing.T) {
	q := neturl.Values{}
	q.Set("track", "夜曲+窃爱 (Live)")
	q.Set("method", "track.getInfo")
	q.Set("artist", "周杰伦")

	want := "artist=%E5%91%A8%E6%9D%B0%E4%BC%A6" +
		"&method=track.getInfo" +
		"&track=%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29"
	if got := lastfmGetQuery(q); got != want {
		t.Errorf("lastfmGetQuery = %q, want %q", got, want)
	}
}
