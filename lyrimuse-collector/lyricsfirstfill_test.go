package main

import (
	"testing"
	"time"
)

func TestNeedsLyricsFirstFill(t *testing.T) {
	now := time.Now().Unix()
	day := int64(24 * 3600)

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{
			name: "空歌词 + 当初解析已超过一天 → 重试",
			e:    enrichEntry{TS: now - day - 60},
			want: true,
		},
		{
			name: "空歌词但刚解析完 → 先别急",
			e:    enrichEntry{TS: now - 60},
			want: false,
		},
		{

			name: "已经有歌词 → 不是这条路径的事(交给升级重试)",
			e:    enrichEntry{TS: now - 30*day, Lyrics: "[00:01.00]x"},
			want: false,
		},
		{
			name: "用户手改过 → 绝不自动重搜",
			e:    enrichEntry{TS: now - 30*day, ManualLyrics: true},
			want: false,
		},
		{

			name: "明确判定为纯音乐 → 不重搜",
			e:    enrichEntry{TS: now - 30*day, Instrumental: true},
			want: false,
		},
		{
			name: "退避:已试 1 次,才过 1 天(要 2 天) → 等着",
			e:    enrichEntry{TS: now - 10*day, LyricsFillCount: 1, LyricsFillTS: now - day - 60},
			want: false,
		},
		{
			name: "退避:已试 1 次,过了 2 天 → 重试",
			e:    enrichEntry{TS: now - 10*day, LyricsFillCount: 1, LyricsFillTS: now - 2*day - 60},
			want: true,
		},
		{
			name: "退避封顶:已试 9 次,过了 16 天 → 仍然重试(没有次数上限)",
			e:    enrichEntry{TS: now - 100*day, LyricsFillCount: 9, LyricsFillTS: now - 16*day - 60},
			want: true,
		},
		{
			name: "退避封顶:已试 9 次,只过了 15 天 → 等着",
			e:    enrichEntry{TS: now - 100*day, LyricsFillCount: 9, LyricsFillTS: now - 15*day},
			want: false,
		},
		{

			name: "起算点取 TS 和 LyricsFillTS 里更晚的那个",
			e:    enrichEntry{TS: now - 60, LyricsFillCount: 0, LyricsFillTS: now - 10*day},
			want: false,
		},
	}
	for _, c := range cases {
		if got := needsLyricsFirstFill(c.e); got != c.want {
			t.Errorf("%s: needsLyricsFirstFill = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestLyricsFillBackoff(t *testing.T) {
	want := []time.Duration{
		24 * time.Hour,
		48 * time.Hour,
		96 * time.Hour,
		8 * 24 * time.Hour,
		16 * 24 * time.Hour,
		16 * 24 * time.Hour,
		16 * 24 * time.Hour,
	}
	counts := []int{0, 1, 2, 3, 4, 5, 99}
	for i, c := range counts {
		if got := lyricsFillBackoff(c); got != want[i] {
			t.Errorf("lyricsFillBackoff(%d) = %v, want %v", c, got, want[i])
		}
	}
}

func TestLyricsUpgradeBaselineEmptyEntry(t *testing.T) {

	baseline, comparable := lyricsUpgradeBaseline(enrichEntry{}, nil)
	if baseline != 0 || !comparable {
		t.Errorf("空歌词条目: baseline=%d comparable=%v, want 0/true", baseline, comparable)
	}

	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion}
	if baseline, comparable = lyricsUpgradeBaseline(e, nil); baseline != 900 || !comparable {
		t.Errorf("有歌词同版本: baseline=%d comparable=%v, want 900/true", baseline, comparable)
	}
}
