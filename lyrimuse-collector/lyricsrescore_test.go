package main

import (
	"testing"
	"time"
)

func TestNeedsLyricsRescore(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	stale := enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion - 1}

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"版本落后:重选", stale, true},
		{
			name: "没有版本号的老条目(读成 0):也算落后,重选",
			e:    enrichEntry{Lyrics: "x"},
			want: true,
		},
		{
			name: "版本已是最新:不碰",
			e:    enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion},
			want: false,
		},
		{
			name: "人工修正过:绝不自动重搜(唯一不可恢复的东西)",
			e:    func() enrichEntry { e := stale; e.ManualLyrics = true; return e }(),
			want: false,
		},
		{
			name: "压根没歌词:交给首次解析那条路,不走这里",
			e:    enrichEntry{LyricsScoringVersion: lyricsScoringVersion - 1},
			want: false,
		},
		{
			name: "本版次数用尽:不为一次规则升级无限重搜",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreVersion = lyricsRescoreMaxAttempts, lyricsScoringVersion
				return e
			}(),
			want: false,
		},
		{
			name: "本版差一次到上限:还重选",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreVersion = lyricsRescoreMaxAttempts-1, lyricsScoringVersion
				return e
			}(),
			want: true,
		},
		{

			name: "次数是旧版本下用掉的:版本再升就解冻(上限按版本计,不是终身)",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreVersion = lyricsRescoreMaxAttempts, lyricsScoringVersion-1
				return e
			}(),
			want: true,
		},
		{

			name: "老条目没记尝试针对的版本、计数超上限:也解冻",
			e:    func() enrichEntry { e := stale; e.LyricsRescoreCount = lyricsRescoreMaxAttempts + 1; return e }(),
			want: true,
		},
		{
			name: "已有逐字歌词也照样重选 —— 规则变了,当初的选择本身就要重新审视",
			e:    func() enrichEntry { e := stale; e.LyricsYRC = "y"; return e }(),
			want: true,
		},
		{
			name: "本版刚尝试过:等间隔到了再来(不然一秒内就把次数烧光,全烧在同一个网络时机上)",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreTS = 1, time.Now().Unix()
				e.LyricsRescoreVersion = lyricsScoringVersion
				return e
			}(),
			want: false,
		},
		{
			name: "本版间隔已过:再试一次",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount = 1
				e.LyricsRescoreTS = time.Now().Unix() - int64(lyricsRescoreDeferInterval/time.Second) - 1
				e.LyricsRescoreVersion = lyricsScoringVersion
				return e
			}(),
			want: true,
		},
		{

			name: "旧版本下刚尝试过(还在节流窗口内):版本一升第一次不套节流",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreTS = 1, time.Now().Unix()
				e.LyricsRescoreVersion = lyricsScoringVersion - 1
				return e
			}(),
			want: true,
		},
	}
	for _, c := range cases {
		if got := needsLyricsRescore(c.e, false, true); got != c.want {
			t.Errorf("%s: needsLyricsRescore = %v, want %v", c.name, got, c.want)
		}
	}

}

func TestAllEnabledLyricSourcesResponded(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "qq": true, "musixmatch": true, "kugou": false})

	full := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
		{Source: "musixmatch", Score: -1},
	}
	if !allEnabledLyricSourcesResponded(full) {
		t.Error("三个启用的源都给出了候选(哪怕其中一份被判无效),应该算信息完整")
	}
	if got := lyricSourcesWithCandidates(full); len(got) != 2 {
		t.Errorf("lyricSourcesWithCandidates 仍应只收有效候选,got %v", got)
	}

	missing := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
	}
	if allEnabledLyricSourcesResponded(missing) {
		t.Error("musixmatch 这轮压根没回来,不该算信息完整")
	}

	if !allEnabledLyricSourcesResponded([]scoredLyricCandidateResult{
		{Source: "netease", Score: 1}, {Source: "qq", Score: 1}, {Source: "musixmatch", Score: 1},
	}) {
		t.Error("被禁用的 kugou 缺席不该影响判断")
	}
}

func TestRescoreDecidable(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "qq": true, "musixmatch": true, "kugou": false})

	partial := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
	}
	if !rescoreDecidable(partial, "netease", false) {
		t.Error("手上这份来自 netease、它这轮回来了:够格重选,不该因为 musixmatch 缺席就推迟")
	}
	if rescoreDecidable(partial, "musixmatch", false) {
		t.Error("手上这份来自 musixmatch、它这轮没回来:什么都不该动")
	}

	if rescoreDecidable(partial, "kugou", false) {
		t.Error("来源已被关掉时退回严格口径,而这一轮缺了 musixmatch,不该够格")
	}
	if rescoreDecidable(partial, "", false) {
		t.Error("老条目没记来源时退回严格口径,而这一轮缺了 musixmatch,不该够格")
	}

	full := append(append([]scoredLyricCandidateResult{}, partial...),
		scoredLyricCandidateResult{Source: "musixmatch", Score: -1})
	if !rescoreDecidable(full, "", false) {
		t.Error("没记来源、但这一轮所有启用的源都回来了:够格")
	}
}

func TestRescoreDecidableNoCurrentLyrics(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "qq": true, "musixmatch": true, "kugou": true})

	onlyKugou := []scoredLyricCandidateResult{{Source: "kugou", Score: 799}}
	if !rescoreDecidable(onlyKugou, "", true) {
		t.Error("手上没有歌词时,只要有候选就该放行 —— 否则这颗按钮对'只有一个源收录'的歌永远失败")
	}

	if !rescoreDecidable(nil, "", true) {
		t.Error("手上没有歌词时,即便这轮空手也该判可判 —— 采纳与否交给下游 Winner 那道闸")
	}

	if rescoreDecidable(onlyKugou, "", false) {
		t.Error("自动 rescore 口径必须一字未动:部分应答 + 没记来源 = 不够格")
	}
}
