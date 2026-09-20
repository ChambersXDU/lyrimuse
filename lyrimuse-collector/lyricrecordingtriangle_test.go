package main

import (
	"os"
	"strings"
	"testing"
)

const (
	triLocalArtist   = "南拳妈妈弹头"
	triLocalTitle    = "枫+退后+搁浅 (Live)"
	triLocalAlbum    = "周杰伦地表最强世界巡回演唱会 (Live)"
	triLocalDuration = 119.213
)

func TestLyricRecordingTriangleOnRealKugouRows(t *testing.T) {
	rows := []struct {
		songName, singer, album string
		duration                float64
		want                    bool
		why                     string
	}{
		{"枫+退后+搁浅 (Live)", "宋健彰", "周杰伦地表最强世界巡回演唱会", 119, true,
			"正主:标题逐字同名 + 专辑宽松包含且长度可比 + 时长 119 对 119.213(0.18%)"},
		{"枫+退后+搁浅", "炸小肉丸", "周杰伦", 62, false,
			"标题少了 (Live) 就过不了逐字同名;即便过了,专辑名是短通用串、时长也差 48%"},
		{"枫+退后+搁浅", "kingwen", "", 119, false,
			"标题对不上;且专辑名为空,三角验证一律不给"},
		{"枫+退后+搁浅", "Jork_FC", "", 119, false, "同上"},
		{"枫 + 退后 + 搁浅", "Lolo, ❁❁", "", 119, false,
			"归一后标题是 枫退后搁浅、少 live;歌手串虽能切出 2 段但与本地无交集"},
		{"枫 + 退后 + 搁浅", "Tsang", "", 119, false, "同上"},
	}
	for _, r := range rows {
		titleOK := lyricTitleAccepted(r.songName, triLocalTitle)
		artistOK := lyricSourceArtistMatches(r.singer, triLocalArtist)
		triOK := lyricRecordingTriangleMatches(r.songName, r.album, r.duration,
			triLocalTitle, triLocalAlbum, triLocalDuration)
		got := titleOK && (artistOK || triOK)
		if got != r.want {
			t.Errorf("闸门对 %q/%q/%q/%gs 判 %v,应为 %v(title=%v artist=%v triangle=%v)——%s",
				r.songName, r.singer, r.album, r.duration, got, r.want, titleOK, artistOK, triOK, r.why)
		}

		if artistOK {
			t.Errorf("lyricSourceArtistMatches(%q, %q) 意外为 true——本案例的前提是它全拒",
				r.singer, triLocalArtist)
		}
	}
}

func TestLyricRecordingTriangleGuards(t *testing.T) {
	cases := []struct {
		name                   string
		candTitle, candAlbum   string
		candDur                float64
		localTitle, localAlbum string
		localDur               float64
		want                   bool
	}{
		{"基准:正主通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},
		{"专辑逐字相等(albumScore=200)也通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},

		{"标题剥括号才相等 → 拒", "枫+退后+搁浅", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"标题双语档 → 拒", "枫+退后+搁浅 (Live) Maple", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"标题空 → 拒", "", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},

		{"时长差 0.9% → 通过", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 1.009,
			triLocalTitle, triLocalAlbum, triLocalDuration, true},
		{"时长差 1.1% → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 1.011,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"时长差 -1.1% → 拒(对称)", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119.213 * 0.989,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选时长缺失 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 0,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"本地时长缺失 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, triLocalAlbum, 0, false},

		{"本地专辑为空 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会", 119,
			triLocalTitle, "", triLocalDuration, false},
		{"候选专辑为空 → 拒", "枫+退后+搁浅 (Live)", "", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选专辑是短通用串(包含档但长度不可比) → 拒", "枫+退后+搁浅 (Live)", "周杰伦", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
		{"候选专辑只是 token 重叠(albumScore<100) → 拒", "枫+退后+搁浅 (Live)", "地表最强 精选集", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},

		{"候选是 Demo 版 → 拒", "枫+退后+搁浅 (Live)", "周杰伦地表最强世界巡回演唱会 (Demo)", 119,
			triLocalTitle, triLocalAlbum, triLocalDuration, false},
	}
	for _, c := range cases {
		got := lyricRecordingTriangleMatches(c.candTitle, c.candAlbum, c.candDur,
			c.localTitle, c.localAlbum, c.localDur)
		if got != c.want {
			t.Errorf("%s:lyricRecordingTriangleMatches(%q,%q,%g, %q,%q,%g) = %v,want %v",
				c.name, c.candTitle, c.candAlbum, c.candDur, c.localTitle, c.localAlbum, c.localDur, got, c.want)
		}
	}
}

func TestLyricRecordingTriangleAlbumWidthBoundary(t *testing.T) {
	const local = "周杰伦地表最强世界巡回纪念集"

	if !lyricRecordingTriangleMatches("X", "周杰伦地表最强世界", 100, "X", local, 100) {
		t.Errorf("9/14=0.643 应通过长度可比性")
	}

	if lyricRecordingTriangleMatches("X", "周杰伦地表最强世", 100, "X", local, 100) {
		t.Errorf("8/14=0.571 应被长度可比性拒掉")
	}
}

func TestLyricRecordingTriangleNotUsedForIdentity(t *testing.T) {
	for _, f := range []string{"netease.go", "qq.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读 %s: %v", f, err)
		}
		if strings.Contains(string(b), "lyricRecordingTriangleMatches") {
			t.Errorf("%s 里出现了 lyricRecordingTriangleMatches —— 这条档位只放行歌词候选,"+
				"不得用于封面/canonical_artist/链接指向这类身份判定,见该函数注释", f)
		}
	}
}
