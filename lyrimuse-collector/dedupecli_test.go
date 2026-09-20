package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoosenEnrichKey(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		same bool
	}{

		{"半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世", true},
		{"中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世", true},

		{"歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來", true},
		{"歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光", true},
		{"大小写", "PRINCE|Kiss|Parade", "Prince|Kiss|Parade", true},

		{"版本括号", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说(Music鉴赏版)|太平盛世", false},
		{"不同专辑", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说|黑色柳丁", false},
		{"不同歌手", "陶喆|Susan 说|太平盛世", "王力宏|Susan 说|太平盛世", false},
		{"Live 版", "周杰伦|晴天|叶惠美", "周杰伦|晴天 (Live)|叶惠美", false},
		{"数字不同", "群星|1 2 3|合辑", "群星|1 2 4|合辑", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := loosenEnrichKey(c.a) == loosenEnrichKey(c.b)
			if got != c.same {
				t.Errorf("loosenEnrichKey(%q)==loosenEnrichKey(%q) = %v, want %v\n  a→%q\n  b→%q",
					c.a, c.b, got, c.same, loosenEnrichKey(c.a), loosenEnrichKey(c.b))
			}
		})
	}
}

func TestLoosenEnrichKeyKnownFalsePositive(t *testing.T) {
	a, b := "群星|1 2 3|合辑", "群星|123|合辑"
	if loosenEnrichKey(a) != loosenEnrichKey(b) {
		t.Fatalf("这条断言是用来记录已知代价的;若实现改成不再折叠它,请一并更新这段注释")
	}
}

func TestPlanDedupeKeepsWinnerOriginalKey(t *testing.T) {
	cache := map[string]enrichEntry{

		"陶喆|Susan 说|太平盛世": {Lyrics: "a", LyricsScore: 1271},
		"陶喆|Susan说|太平盛世":  {Lyrics: "b", LyricsScore: 1274},

		"陶喆|Susan 说(Music鉴赏版)|太平盛世": {Lyrics: "c", LyricsScore: 1269},

		"孙燕姿|逆光|逆光": {Lyrics: "d", LyricsScore: 900},
	}
	plan := planDedupe(cache)
	if len(plan.groups) != 1 {
		t.Fatalf("groups = %d, want 1: %+v", len(plan.groups), plan.groups)
	}
	g := plan.groups[0]

	if g.source != "陶喆|Susan说|太平盛世" {
		t.Errorf("source = %q, want 陶喆|Susan说|太平盛世(分数更高的那条)", g.source)
	}

	if g.winner != "陶喆|Susan 说|太平盛世" {
		t.Errorf("winner = %q, want 陶喆|Susan 说|太平盛世(排版更好的写法)", g.winner)
	}
	if len(g.losers) != 1 || g.losers[0] != "陶喆|Susan说|太平盛世" {
		t.Errorf("losers = %v, want [陶喆|Susan说|太平盛世]", g.losers)
	}

	if _, ok := cache[g.winner]; !ok {
		t.Errorf("winner %q 不是缓存里的原始 key —— 落盘会写出一个谁都不这么写的串", g.winner)
	}
}

func TestPlanDedupeIsDeterministic(t *testing.T) {

	cache := map[string]enrichEntry{
		"孙燕姿|我怀念的|逆光": {Lyrics: "a", LyricsScore: 1000},
		"孙燕姿|我懷念的|逆光": {Lyrics: "b", LyricsScore: 1000},
		"孫燕姿|我懷念的|逆光": {Lyrics: "c", LyricsScore: 1000},
	}
	first := planDedupe(cache)
	if len(first.groups) != 1 || len(first.groups[0].losers) != 2 {
		t.Fatalf("期望 1 组 2 个落败者,得到 %+v", first.groups)
	}
	for i := 0; i < 200; i++ {
		got := planDedupe(cache)
		if got.groups[0].winner != first.groups[0].winner {
			t.Fatalf("第 %d 次胜者变成 %q(首次是 %q)—— 并列时的选择必须是确定的",
				i, got.groups[0].winner, first.groups[0].winner)
		}
	}
}

func TestResolveStaleFilesNeverTouchesWinner(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	winner := "陶喆|Susan说|太平盛世"
	loser := "陶喆|Susan 说|太平盛世"

	for _, k := range []string{winner, loser} {
		for _, name := range enrichExportedFileNames(k) {
			p := filepath.Join(dir, name)
			if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	plan := dedupePlan{groups: []dedupeGroup{{winner: winner, source: winner, losers: []string{loser}}}}
	stale := resolveStaleFiles(plan)
	if len(stale) == 0 {
		t.Fatal("落败条目的导出文件一个都没列出来 —— 不删的话下次启动会把它导回来")
	}
	winnerNames := map[string]bool{}
	for _, n := range enrichExportedFileNames(winner) {
		winnerNames[n] = true
	}
	for _, f := range stale {
		if winnerNames[filepath.Base(f)] {
			t.Errorf("胜者的导出文件 %q 出现在待删清单里", filepath.Base(f))
		}
	}
}

func TestResolveStaleFilesOnlyExisting(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	plan := dedupePlan{groups: []dedupeGroup{{
		winner: "陶喆|Susan说|太平盛世",
		source: "陶喆|Susan说|太平盛世",
		losers: []string{"陶喆|Susan 说|太平盛世"},
	}}}
	if got := resolveStaleFiles(plan); len(got) != 0 {
		t.Errorf("空目录下列出了 %v", got)
	}
}

func TestPickDisplayKeyPrefersSimplifiedThenSpaced(t *testing.T) {
	cases := []struct {
		name string
		keys []string
		want string
	}{
		{
			"简体优先于繁体",
			[]string{"方大同|千紙鶴|回到未來", "方大同|千纸鹤|回到未來"},
			"方大同|千纸鹤|回到未來",
		},
		{
			"歌手名也算",
			[]string{"孫燕姿|我懷念的|逆光", "孙燕姿|我懷念的|逆光", "孙燕姿|我怀念的|逆光"},
			"孙燕姿|我怀念的|逆光",
		},
		{
			"同为简体时取有空格的",
			[]string{"陶喆|Susan说|太平盛世", "陶喆|Susan 说|太平盛世"},
			"陶喆|Susan 说|太平盛世",
		},
		{
			"专辑名本来就是繁体也不影响(两条都非简体时仍按空格挑)",
			[]string{"丁世光|小师妹|神經志 The Journal", "丁世光|小師妹|神經志 The Journal"},
			"丁世光|小师妹|神經志 The Journal",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := pickDisplayKey(c.keys); got != c.want {
				t.Errorf("pickDisplayKey(%v) = %q, want %q", c.keys, got, c.want)
			}
		})
	}
}

func TestResolveStaleFilesIncludesWinnerWhenContentMovedIn(t *testing.T) {
	dir := t.TempDir()
	old := lyricsDir
	lyricsDir = dir
	t.Cleanup(func() { lyricsDir = old })

	winner := "陶喆|Susan 说|太平盛世"
	source := "陶喆|Susan说|太平盛世"
	for _, k := range []string{winner, source} {
		for _, name := range enrichExportedFileNames(k) {
			if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	plan := dedupePlan{groups: []dedupeGroup{{
		winner: winner, source: source, losers: []string{source},
	}}}
	stale := resolveStaleFiles(plan)
	names := map[string]bool{}
	for _, f := range stale {
		names[filepath.Base(f)] = true
	}
	for _, n := range enrichExportedFileNames(winner) {
		if _, err := os.Stat(filepath.Join(dir, n)); err == nil && !names[n] {
			t.Errorf("winner 的旧文件 %q 没进待删清单 —— 它装的还是落败正文", n)
		}
	}
}
