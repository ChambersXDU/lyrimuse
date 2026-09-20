package main

import "testing"

func TestPickKugouSearchCandidate(t *testing.T) {

	realPage := []kugouSong{
		{Hash: "H0", SongName: "简单爱 (无与伦比演唱会 m 56s)", SingerName: "周杰伦", AlbumName: "", Duration: 56},
		{Hash: "H1", SongName: "简单爱 (Live)", SingerName: "周杰伦", AlbumName: "The One 演唱会", Duration: 273},
		{Hash: "H2", SongName: "简单爱 (Live)", SingerName: "周杰伦", AlbumName: "周杰伦 2004 无与伦比 演唱会 Live CD", Duration: 393},
		{Hash: "H3", SongName: "简单爱", SingerName: "周杰伦", AlbumName: "范特西", Duration: 270},
		{Hash: "H4", SongName: "简单爱 (Live)", SingerName: "周杰伦、陈奕迅", AlbumName: "2015江苏卫视新年演唱会", Duration: 313},
	}

	t.Run("真实案例:56秒片段不再顶掉标题精确+专辑对得上+时长吻合的正主", func(t *testing.T) {
		got := pickKugouSearchCandidate(realPage, "周杰伦", "简单爱 (Live)", "The One 周杰伦演唱会", 273.227)
		if got == nil || got.Hash != "H1" {
			t.Fatalf("想要 H1(The One 版),拿到 %+v", got)
		}
	})

	t.Run("标题档位:normLoose 精确同名压过剥括号档,与出现顺序无关", func(t *testing.T) {

		songs := []kugouSong{
			{Hash: "A", SongName: "简单爱 (别的场次)", SingerName: "周杰伦", Duration: 273},
			{Hash: "B", SongName: "简单爱 (Live)", SingerName: "周杰伦", Duration: 275},
		}
		got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "", 273.227)
		if got == nil || got.Hash != "B" {
			t.Fatalf("精确同名该赢,拿到 %+v", got)
		}
	})

	t.Run("真实案例:自报曲长对不上的精确同名不再压过对得上的剥括号版(PRINCE《319》X-cerpt)", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "7cd854d9", SongName: "319", SingerName: "Prince", AlbumName: "The Gold Experience (Explicit)", Duration: 185},
			{Hash: "43aafa89", SongName: "319 (X-cerpt)", SingerName: "Prince", AlbumName: "The VERSACE Experience (PRELUDE 2 GOLD) [Explicit]", Duration: 88},
			{Hash: "2976407b", SongName: "319", SingerName: "Prince", AlbumName: "3 Nites In Miami Glam Slam '94", Duration: 310},
		}
		got := pickKugouSearchCandidate(songs, "PRINCE", "319", "The VERSACE Experience Prelude 2 Gold", 88.226)
		if got == nil || got.Hash != "43aafa89" {
			t.Fatalf("88 秒的 X-cerpt 该赢,拿到 %+v", got)
		}

		got = pickKugouSearchCandidate(songs, "PRINCE", "319", "The Gold Experience", 185.12)
		if got == nil || got.Hash != "7cd854d9" {
			t.Fatalf("185 秒的专辑版该赢,拿到 %+v", got)
		}

		got = pickKugouSearchCandidate(songs, "PRINCE", "319", "The VERSACE Experience Prelude 2 Gold", 0)
		if got == nil || got.Hash != "7cd854d9" {
			t.Fatalf("时长未知时应回到纯标题档,拿到 %+v", got)
		}
	})

	t.Run("同档位比专辑分", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "A", SongName: "简单爱 (Live)", SingerName: "周杰伦", AlbumName: "", Duration: 273},
			{Hash: "B", SongName: "简单爱 (Live)", SingerName: "周杰伦", AlbumName: "The One 周杰伦演唱会", Duration: 273},
		}
		got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "The One 周杰伦演唱会", 0)
		if got == nil || got.Hash != "B" {
			t.Fatalf("专辑精确对上的该赢,拿到 %+v", got)
		}
	})

	t.Run("同档同专辑分比时长贴近度", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "A", SongName: "简单爱 (Live)", SingerName: "周杰伦", Duration: 393},
			{Hash: "B", SongName: "简单爱 (Live)", SingerName: "周杰伦", Duration: 273},
		}
		got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "", 273.227)
		if got == nil || got.Hash != "B" {
			t.Fatalf("时长更贴近的该赢,拿到 %+v", got)
		}
	})

	t.Run("全部打平保持原序(=改动前行为)", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "A", SongName: "简单爱", SingerName: "周杰伦", Duration: 270},
			{Hash: "B", SongName: "简单爱", SingerName: "周杰伦", Duration: 270},
		}
		got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱", "", 270)
		if got == nil || got.Hash != "A" {
			t.Fatalf("打平该保持原序取第一条,拿到 %+v", got)
		}
	})

	t.Run("标题闸照旧:一条都不沾边时返回 nil", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "A", SongName: "晴天", SingerName: "周杰伦", Duration: 269},
		}
		if got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "", 273.227); got != nil {
			t.Fatalf("不该有候选,拿到 %+v", got)
		}
	})

	t.Run("歌手闸不过时仍有同一次录音三角判据兜底", func(t *testing.T) {
		songs := []kugouSong{

			{Hash: "A", SongName: "简单爱 (Live)", SingerName: "周董", AlbumName: "The One 周杰伦演唱会", Duration: 273},
		}
		got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "The One 周杰伦演唱会", 273.227)
		if got == nil || got.Hash != "A" {
			t.Fatalf("三角判据该放行,拿到 %+v", got)
		}
	})

	t.Run("缺 hash 的条目照旧忽略", func(t *testing.T) {
		songs := []kugouSong{
			{Hash: "", SongName: "简单爱 (Live)", SingerName: "周杰伦", Duration: 273},
		}
		if got := pickKugouSearchCandidate(songs, "周杰伦", "简单爱 (Live)", "", 273.227); got != nil {
			t.Fatalf("缺 hash 拿不了歌词,不该返回,拿到 %+v", got)
		}
	})
}
