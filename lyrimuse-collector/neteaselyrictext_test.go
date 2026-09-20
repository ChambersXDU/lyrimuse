package main

import "testing"

func TestStripNeteaseEscapedApostrophes(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"无反斜杠原样返回", "普通歌词，没有转义", "普通歌词，没有转义"},
		{"清掉撇号前的反斜杠", `Can\'t see what\'s the point`, "Can't see what's the point"},
		{"多行都清", "[00:04.04]CAN\\'T LET HER GET AWAY\n[01:11.09]I\\'ll play the fool", "[00:04.04]CAN'T LET HER GET AWAY\n[01:11.09]I'll play the fool"},
		{"空串", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := stripNeteaseEscapedApostrophes(c.in); got != c.want {
				t.Errorf("stripNeteaseEscapedApostrophes(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
