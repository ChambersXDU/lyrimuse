package main

import (
	"fmt"
	"strings"
	"testing"
)

func lrcTo(sec int) string {
	var b strings.Builder
	for i := 0; i <= sec; i += 10 {
		fmt.Fprintf(&b, "[%02d:%02d.00]line %d\n", i/60, i%60, i)
	}
	return b.String()
}

func yrcTo(ms int) string {
	var b strings.Builder
	for i := 0; i <= ms; i += 10000 {
		fmt.Fprintf(&b, "[%d,900](%d,900,0)word\n", i, i)
	}
	return b.String()
}

func TestUsableWordTiming(t *testing.T) {
	lyrics := lrcTo(260)

	cases := []struct {
		name string
		yrc  string
		want bool
	}{

		{"截断到 19%", yrcTo(50_000), false},

		{"正常 85%", yrcTo(222_000), true},
		{"完整", yrcTo(260_000), true},
		{"恰好过线 50%", yrcTo(130_000), true},
		{"差一点 49%", yrcTo(127_000), false},
		{"空", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := usableWordTiming(lyrics, c.yrc); got != c.want {
				t.Errorf("usableWordTiming = %v, want %v (yrcEnd=%d lrcEnd=%d)",
					got, c.want, lastYRCTimestampMs(c.yrc), lastLRCTimestampMs(lyrics))
			}

			gotYRC := usableYRC(lyrics, c.yrc)
			if (gotYRC != "") != c.want {
				t.Errorf("usableYRC 跟 usableWordTiming 不一致")
			}
		})
	}
}

func TestUsableWordTimingFailsOpenWhenUncomparable(t *testing.T) {
	if !usableWordTiming("", yrcTo(50_000)) {
		t.Error("整行歌词没有时间戳时应放行")
	}
	if !usableWordTiming(lrcTo(200), "[无法解析的内容]") {
		t.Error("逐字侧解析不出时间戳时应放行")
	}
}

func TestLastTimestampParsers(t *testing.T) {

	if got := lastLRCTimestampMs("[00:10.50]x\n"); got != 10_500 {
		t.Errorf("厘秒解析错: %d", got)
	}
	if got := lastLRCTimestampMs("[00:10.500]x\n"); got != 10_500 {
		t.Errorf("毫秒解析错: %d", got)
	}
	if got := lastYRCTimestampMs("[1000,500](1000,500,0)a\n[2000,750](2000,750,0)b\n"); got != 2_750 {
		t.Errorf("YRC 末尾解析错: %d", got)
	}
}
