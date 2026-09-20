package main

import "testing"

func TestQQAlbumIdentityQuery(t *testing.T) {
	cases := []struct {
		artist, album, want string
	}{

		{"周杰伦", "The One 周杰伦演唱会", "the one"},

		{"陈奕迅", "The Easy Ride 演唱会 (Live)", "the easy ride"},

		{"蔡健雅", "My Space 演唱會紀念盤", "my space 纪念盘"},

		{"Eason Chan", "Get A Life Concert", "get a life"},

		{"周杰伦", "八度空间", "八度空间"},
	}
	for _, c := range cases {
		if got := qqAlbumIdentityQuery(c.artist, c.album); got != c.want {
			t.Errorf("qqAlbumIdentityQuery(%q, %q) = %q, want %q", c.artist, c.album, got, c.want)
		}
	}
}
