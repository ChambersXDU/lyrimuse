package main

import "testing"

func TestToSimplifiedT2S(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"我們是工農子弟兵", "我们是工农子弟兵"},

		{"乾脆說得清楚點", "干脆说得清楚点"},

		{"情有獨鍾", "情有独钟"},

		{"乾隆年間", "乾隆年间"},

		{"乾燥", "干燥"},

		{"周杰倫的歌詞ABC123😀", "周杰伦的歌词ABC123😀"},

		{"hello world 123", "hello world 123"},
	}
	for _, c := range cases {
		if got := toSimplifiedT2S(c.in); got != c.want {
			t.Errorf("toSimplifiedT2S(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
