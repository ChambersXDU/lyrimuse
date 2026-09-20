package main

import "testing"

func TestIsAllHan(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"重要", true},
		{"這個", true},
		{"笑左，笑埋右", false},
		{"hee hee hur hur", false},
		{"重要3", false},
		{"", true},

	}
	for _, c := range cases {
		if got := isAllHan(c.in); got != c.want {
			t.Errorf("isAllHan(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestJyutpingWordMapHasNoPunctuationKeys(t *testing.T) {
	for word := range jyutpingWordMap {
		if !isAllHan(word) {
			t.Fatalf("jyutpingWordMap contains a non-Han key %q — toJyutpingLine would silently drop its non-Han characters when this word matches", word)
		}
	}
}

func TestToJyutpingLine(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"单字", "我", "ngo5"},
		{"多字连读", "我哋", "ngo5 dei6"},
		{"粤语虚词(HanVariants 里明确保留的那几个)", "唔該你", "m4 goi1 nei5"},
		{"拉丁词不该被拆开", "Baby 我爱你", "Baby ngo5 oi3 nei5"},
		{"标点前后都要有分隔", "你好，世界", "nei5 hou2 ， sai3 gaai3"},

		{"简体字走 s2t 兜底 + 命中词级消歧(這個≠這单字)", "这个世界", "ze3 go3 sai3 gaai3"},
		{"查不到读音的字符原样穿透", "我😀你", "ngo5 😀 nei5"},
		{"空串", "", ""},

		{"多音字消歧: 重要", "重要", "zung6 jiu3"},
		{"多音字消歧: 重量(同一个字,不同词,不同读音)", "重量", "cung5 loeng6"},
		{"多音字消歧在整句里也生效", "呢件事好重要", "nei1 gin6 si6 hou2 zung6 jiu3"},

		{"字表碰撞覆盖: 单独一个离字(不构成任何词)", "离", "lei4"},
		{"字表碰撞覆盖: 在句子里单独出现", "我要离", "ngo5 jiu3 lei4"},
		{"字表碰撞覆盖: 词表命中的离开不受影响(双重验证同一个字两条路径都对)", "离开", "lei4 hoi1"},

		{"最长匹配优先: 唔該晒不能被短词唔該截断", "唔該晒", "m4 goi1 saai3"},

		{"拉丁紧接汉字要分隔(修前粘成 babyngo5)", "baby我爱你", "baby ngo5 oi3 nei5"},
		{"大写同理(修前粘成 OKlaa1)", "OK啦", "OK laa1"},
		{"汉字—拉丁—汉字两侧都要分隔(修前粘成 lovenei5)", "我love你", "ngo5 love nei5"},
		{"拉丁串内部仍然不拆", "Do re mi当中", "Do re mi dong1 zung1"},
		{"数字紧接汉字", "3个", "3 go3"},

		{"查不到读音的汉字后面也要分隔", "𠮷我", "𠮷 ngo5"},

		{"纯英文原样穿透、撇号不劈词", "that’s all", "that’s all"},
	}
	for _, c := range cases {
		if got := toJyutpingLine(c.in); got != c.want {
			t.Errorf("%s: toJyutpingLine(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestJyutpingLRC(t *testing.T) {
	lrc := "[00:01.00]我愛你\n[00:03.50]我哋今日好開心"
	got := jyutpingLRC(lrc)
	want := "[00:01.00]ngo5 oi3 nei5\n[00:03.50]ngo5 dei6 gam1 jat6 hou2 hoi1 sam1"
	if got != want {
		t.Errorf("jyutpingLRC(%q) = %q, want %q", lrc, got, want)
	}
}

func TestJyutpingLRCEmpty(t *testing.T) {
	if got := jyutpingLRC(""); got != "" {
		t.Errorf("jyutpingLRC(\"\") = %q, want empty", got)
	}

	if got := jyutpingLRC("没有时间戳的纯文本"); got != "" {
		t.Errorf("jyutpingLRC(no timestamps) = %q, want empty", got)
	}
}

func TestMaybeGenerateJyutpingRoma(t *testing.T) {
	cases := []struct {
		name     string
		entry    enrichEntry
		wantRoma string
	}{
		{
			name:     "粤语且罗马音为空 → 应该补上",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你"},
			wantRoma: "[00:01.00]ngo5 oi3 nei5",
		},
		{
			name:     "已有罗马音 → 不覆盖",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]我愛你", LyricsRoma: "[00:01.00]existing"},
			wantRoma: "[00:01.00]existing",
		},
		{
			name:     "国语歌不该生成粤拼",
			entry:    enrichEntry{SongLanguage: songLanguageMandarin, Lyrics: "[00:01.00]我愛你"},
			wantRoma: "",
		},
		{
			name:     "语种未知不该生成粤拼",
			entry:    enrichEntry{SongLanguage: "", Lyrics: "[00:01.00]我愛你"},
			wantRoma: "",
		},
		{
			name:     "没有歌词正文不该生成",
			entry:    enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: ""},
			wantRoma: "",
		},
	}
	for _, c := range cases {
		e := c.entry
		e.maybeGenerateJyutpingRoma()
		if e.LyricsRoma != c.wantRoma {
			t.Errorf("%s: LyricsRoma = %q, want %q", c.name, e.LyricsRoma, c.wantRoma)
		}
	}
}
