package main

import (
	"testing"
	"time"
)

func TestNeedsPeripheralBackfill(t *testing.T) {
	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	full := enrichEntry{
		AccentColor: "#fff", AppleURL: "a", QQURL: "q", NeteaseURL: "n",
		CanonicalArtist: "窦靖童", TS: long,
	}

	cases := []struct {
		name   string
		e      enrichEntry
		artist string
		want   bool
	}{
		{"什么都不缺:不补", full, "窦靖童", false},
		{"缺主色:补", func() enrichEntry { e := full; e.AccentColor = ""; return e }(), "窦靖童", true},
		{"缺网易云链接:补", func() enrichEntry { e := full; e.NeteaseURL = ""; return e }(), "窦靖童", true},
		{
			name:   "单一歌手缺 canonical:补(这条以前会被漏掉)",
			e:      func() enrichEntry { e := full; e.CanonicalArtist = ""; return e }(),
			artist: "窦靖童", want: true,
		},
		{
			name:   "合唱曲目缺 canonical:不补 —— collector 只在单一歌手时才给值,空是正常的",
			e:      func() enrichEntry { e := full; e.CanonicalArtist = ""; return e }(),
			artist: "窦靖童 & Lionman", want: false,
		},
		{
			name:   "还没到节流窗口:不补",
			e:      func() enrichEntry { e := full; e.AccentColor = ""; e.TS = time.Now().Unix(); return e }(),
			artist: "窦靖童", want: false,
		},
		{
			name: "重试次数用尽:不补(以前没有这道闸,会无限重试)",
			e: func() enrichEntry {
				e := full
				e.AccentColor = ""
				e.PeripheralRetryCount = peripheralBackfillMaxAttempts
				return e
			}(),
			artist: "窦靖童", want: false,
		},

		{
			name: "QQ 链接还是搜索兜底:补(以前永远不补)",
			e: func() enrichEntry {
				e := full
				e.QQURL = qqSearchFallbackPrefix + "w=x"
				return e
			}(),
			artist: "窦靖童", want: true,
		},
		{
			name: "有真·歌曲页但缺专辑 mid:补",
			e: func() enrichEntry {
				e := full
				e.QQURL = "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"
				e.QQSingerMid = "s"
				return e
			}(),
			artist: "窦靖童", want: true,
		},
		{
			name: "真·歌曲页且两个 mid 都在:不补",
			e: func() enrichEntry {
				e := full
				e.QQURL = "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"
				e.QQAlbumMid, e.QQSingerMid = "a", "s"
				return e
			}(),
			artist: "窦靖童", want: false,
		},
		{
			name: "差一次到上限:还补",
			e: func() enrichEntry {
				e := full
				e.AccentColor = ""
				e.PeripheralRetryCount = peripheralBackfillMaxAttempts - 1
				return e
			}(),
			artist: "窦靖童", want: true,
		},

		{
			name:   "周杰伦只缺网易云链接:不补(那个链接是故意不给的)",
			e:      func() enrichEntry { e := full; e.NeteaseURL = ""; return e }(),
			artist: "周杰伦", want: false,
		},
		{
			name:   "周杰伦缺网易云链接又缺主色:补(名单只免掉网易云这一项)",
			e:      func() enrichEntry { e := full; e.NeteaseURL = ""; e.AccentColor = ""; return e }(),
			artist: "周杰伦", want: true,
		},
	}
	for _, c := range cases {
		if got := needsPeripheralBackfill(c.e, c.artist, ""); got != c.want {
			t.Errorf("%s: needsPeripheralBackfill = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPeripheralThrottleDoesNotDelayLyricsRetry(t *testing.T) {
	saved := getFeaturesLyricsSources()
	defer func() { setFeaturesLyricsSources(saved) }()
	setFeaturesLyricsSources(map[string]bool{"netease": true, "kugou": true})

	longAgo := time.Now().Unix() - int64(lyricsRetryInterval/time.Second) - 1
	e := enrichEntry{
		Lyrics:            "[00:01.00]hello",
		LyricsSourcesSeen: []string{"netease"},
		TS:                longAgo,
	}
	if !needsLyricsRetry(e, false, false, true) {
		t.Fatal("间隔已过、又确实缺源,本来就该重搜")
	}

	e.PeripheralTS = time.Now().Unix()
	e.PeripheralRetryCount++
	if !needsLyricsRetry(e, false, false, true) {
		t.Error("补了一次外围字段就把歌词重搜挡掉了 —— 两个节流又耦合回去了")
	}

	if needsPeripheralBackfill(e, "someone", "") {
		t.Error("外围补全刚跑过,10 分钟内不该再来")
	}
}
