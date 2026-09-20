package main

import "testing"

func TestWithholdImpersonatorRiddenIdentity(t *testing.T) {
	full := neteaseInfo{
		Cover:        "https://p1.music.126.net/cover.jpg",
		SongURL:      "https://music.163.com/song?id=1400391910",
		Lyrics:       "[00:17.45]才离开没多久就开始",
		Trans:        "[00:17.45]translated",
		Roma:         "[00:17.45]cai li kai",
		YRC:          `{"t":17450,"c":[{"tx":"才"}]}`,
		DurationSecs: 272.973,
		Artist:       "周杰伦",
		Title:        "开不了口 (Live)",
		Album:        "周杰伦地表最强世界巡回演唱会",
		AlbumID:      123456,
		PureMusic:    true,
	}

	t.Run("非黑名单艺人原样透传", func(t *testing.T) {
		got := withholdImpersonatorRiddenIdentity("Addison Rae", full)
		if got != full {
			t.Errorf("withholdImpersonatorRiddenIdentity(非黑名单) 改动了字段:\n got  %+v\n want %+v", got, full)
		}
	})

	t.Run("黑名单艺人只留歌词族与打分输入", func(t *testing.T) {
		got := withholdImpersonatorRiddenIdentity("周杰伦", full)

		if got.Cover != "" {
			t.Errorf("Cover 必须扣下(封面选源要退到 Apple),got %q", got.Cover)
		}
		if got.Artist != "" {
			t.Errorf("Artist 必须扣下(它会被写进 canonical_artist),got %q", got.Artist)
		}
		if got.SongURL != "" {
			t.Errorf("SongURL 必须扣下(它会被写进 netease_url),got %q", got.SongURL)
		}
		if got.AlbumID != 0 {
			t.Errorf("AlbumID 必须扣下(专辑预取会拿它拉整张曲目表),got %d", got.AlbumID)
		}
		if got.PureMusic {
			t.Error("PureMusic 必须扣下:这类艺人的曲库记录不可信,不该由它下「本来就没词」的结论——" +
				"那个标记会挡掉后续重搜(needsLyricsFirstFill)")
		}

		if got.Lyrics != full.Lyrics || got.Trans != full.Trans ||
			got.Roma != full.Roma || got.YRC != full.YRC {
			t.Errorf("歌词族必须原样放行,got %+v", got)
		}
		if got.Title != full.Title {
			t.Errorf("Title 必须放行(lyricTitleAccepted / versionTagsMismatch 的输入),got %q", got.Title)
		}
		if got.Album != full.Album {
			t.Errorf("Album 必须放行(albumScore / versionTagsMismatch 的输入),got %q", got.Album)
		}
		if got.DurationSecs != full.DurationSecs {
			t.Errorf("DurationSecs 必须放行(时长吻合/overshoot 那两档的输入),got %v", got.DurationSecs)
		}
	})

	t.Run("繁体写法同样按黑名单处理", func(t *testing.T) {
		if got := withholdImpersonatorRiddenIdentity("周杰倫", full); got.Cover != "" || got.Artist != "" {
			t.Errorf("繁体名也在 neteaseImpersonatorRiddenArtists 里,身份/封面同样要扣下,got %+v", got)
		}
	})
}
