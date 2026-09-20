package main

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

func TestIsCreditOnlyLRC(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		want bool
	}{
		{
			name: "完整虚构制作人员名单,角色名远超旧版枚举词表",
			lrc: "[00:00.00]作曲: 甲\n" +
				"[00:01.00]制作人: 乙\n" +
				"[00:02.00]指挥: 丙\n" +
				"[00:03.00]混音师: 丁\n" +
				"[00:04.00]贝斯: 戊\n" +
				"[00:05.00]中提琴: 己\n" +
				"[00:06.00]吉他: 庚\n" +
				"[00:07.00]大提琴: 辛\n" +
				"[04:35.19]母带工程师: 壬",
			want: true,
		},
		{
			name: "网易云纯音乐占位文案本身也应该被识别",
			lrc: "[00:00.00]作曲: 甲\n" +
				"[00:01.00]纯音乐，请欣赏\n" +
				"[04:00.00]制作人: 乙",
			want: true,
		},
		{
			name: "旧版枚举关键词表仍然覆盖(英文写法)",
			lrc: "[00:00.00]composed by: 甲\n" +
				"[04:00.00]produced by: 乙",
			want: true,
		},
		{
			name: "真正的歌词正文不应该被误伤(非职员表结构,行数达标)",
			lrc: "[00:00.00]作词: 甲\n" +
				"[00:10.00]占位歌词行一二三四五六\n" +
				"[00:20.00]占位歌词行七八九十十一\n" +
				"[00:30.00]占位歌词行十二十三十四十五",
			want: false,
		},
	}
	for _, c := range cases {
		if got := isCreditOnlyLRC(c.lrc); got != c.want {
			t.Errorf("%s: isCreditOnlyLRC() = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestScoreLyricCandidateRejectsCreditOnlyLyrics(t *testing.T) {
	fakeCreditLRC := "[00:00.00]作曲: 甲\n" +
		"[00:01.00]制作人: 乙\n" +
		"[00:02.00]指挥: 丙\n" +
		"[00:03.00]混音师: 丁\n" +
		"[00:04.00]贝斯: 戊\n" +
		"[00:05.00]中提琴: 己\n" +
		"[00:06.00]吉他: 庚\n" +
		"[00:07.00]大提琴: 辛\n" +
		"[04:35.19]母带工程师: 壬"
	c := lyricCandidate{source: "netease", lyrics: fakeCreditLRC}
	if got := scoreLyricCandidate("Someone", "Instrumental Track", "", 275.19, c, false, 0); got != -1 {
		t.Errorf("scoreLyricCandidate() = %d, want -1 (credit-only lyrics must be rejected)", got)
	}
}

func TestTitleVersionTags(t *testing.T) {
	cases := []struct {
		title string
		want  []string
	}{

		{"Blue Gangsta (Original Version)", []string{"original version"}},
		{"Beat It (Demo)", []string{"demo"}},
		{"Billie Jean [Live]", []string{"live"}},
		{"Thriller (Instrumental)", []string{"instrumental"}},
		{"Bad (Extended Dance Remix)", []string{"remix", "extended"}},

		{"Smooth Criminal - Live at Wembley", []string{"live"}},

		{"Thriller (2001 Remastered)", nil},
		{"Bad (Deluxe Edition)", nil},
		{"Beat It (Explicit)", nil},

		{"Live and Let Die", nil},
		{"Demolition Man", nil},
		{"Remixing My Heart", nil},
		{"Instrumentality", nil},

		{"Blue Gangsta", nil},
		{"", nil},

		{"Blue Gangsta (Demo", []string{"demo"}},

		{"蜗牛 (伴奏)", []string{"instrumental"}},
		{"起风了 (Live)", []string{"live"}},
		{"晴天 [现场版]", []string{"live"}},
		{"告白气球 (阿卡贝拉版本)", []string{"a cappella"}},
		{"Song (Acapella)", []string{"a cappella"}},
		{"Song (A Cappella)", []string{"a cappella"}},
		{"晴天 (不插电)", []string{"unplugged"}},
		{"晴天 (混音)", []string{"remix"}},

		{"不插电的夏天", nil},

		{"Diamonds And Pearls (Edit)", []string{"edit"}},
		{"Man In the Mirror (2003 Edit)", []string{"edit"}},
		{"Everybody (Backstreet's Back) (Radio Edit)", []string{"radio edit", "edit"}},

		{"Thriller (Deluxe Edition)", nil},
		{"Purple Rain (Expanded Edition)", nil},
		{"Editor's Cut (Live)", []string{"live"}},
	}
	for _, c := range cases {
		got := titleVersionTags(c.title)
		if len(got) != len(c.want) {
			t.Errorf("titleVersionTags(%q) = %v, want %v", c.title, got, c.want)
			continue
		}
		for _, w := range c.want {
			if !got[w] {
				t.Errorf("titleVersionTags(%q) = %v, 缺 %q", c.title, got, w)
			}
		}
	}
}

func TestVersionTagsMismatchFoldsBilingualSynonyms(t *testing.T) {
	cases := []struct {
		name                 string
		localTitle, localAlb string
		candTitle, candAlb   string
		want                 bool
	}{
		{"陶喆 今天没回家:曲名 Live + 专辑括号「现场」 vs Live/Live Concert", "今天没回家 (Live)", "Soul Power (现场原音专辑)", "今天没回家 (Live)", "Soul Power (Live Concert)", false},
		{"同案 网易云:专辑「Soul Power Live 陶喆现场原音专辑」", "今天没回家 (Live)", "Soul Power (现场原音专辑)", "今天没回家 (Live)", "Soul Power Live 陶喆现场原音专辑", false},
		{"(Live) 对 (现场) 是同一个版本", "龙拳 (Live)", "The One", "龙拳 (现场)", "The One 演唱会", false},
		{"(现场) 对 (Live) 反向同理", "龙拳 (现场)", "The One", "龙拳 (Live)", "The One", false},
		{"(Unplugged) 对 (不插电)", "晴天 (Unplugged)", "", "晴天 (不插电)", "", false},
		{"(Acapella) 对 (A Cappella) 两种拼法", "Song (Acapella)", "", "Song (A Cappella)", "", false},
		{"(Instrumental) 对 (伴奏)", "蜗牛 (Instrumental)", "", "蜗牛 (伴奏)", "", false},

		{"正式版 对 (现场) 仍是版本不符", "龙拳", "The One", "龙拳 (现场)", "", true},
		{"(Live) 对 (伴奏) 仍是版本不符", "蜗牛 (Live)", "", "蜗牛 (伴奏)", "", true},
		{"(现场) 对 正式版 仍是版本不符", "龙拳 (现场)", "", "龙拳", "The One", true},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.localTitle, c.localAlb, c.candTitle, c.candAlb); got != c.want {
			t.Errorf("%s: versionTagsMismatch = %v, want %v(本地 %v / 候选 %v)", c.name, got, c.want,
				recordingVersionTags(c.localTitle, c.localAlb), recordingVersionTags(c.candTitle, c.candAlb))
		}
	}

	inVocab := map[string]bool{}
	for _, tag := range distinctRecordingVersionTags {
		inVocab[tag] = true
	}
	for alias, canon := range versionTagAliases {
		if !inVocab[alias] {
			t.Errorf("别名 %q 不在 distinctRecordingVersionTags 里,永远匹配不到", alias)
		}
		if !inVocab[canon] {
			t.Errorf("规范键 %q(来自 %q)不在词表里", canon, alias)
		}
		if _, chained := versionTagAliases[canon]; chained {
			t.Errorf("规范键 %q 自己又有别名,折键会不稳定", canon)
		}
	}

	lyr := "[00:10.00]占位第一句\n[00:12.00]占位第二句\n[00:14.00]占位第三句\n[04:00.00]占位末句"
	cand := lyricCandidate{source: "kugou", lyrics: lyr, hasWordTiming: true, sourceReportedDurationSecs: 245,
		title: "今天没回家 (Live)", artist: "陶喆", album: "Soul Power (Live Concert)"}
	_, terms := scoreLyricCandidateDetailed("陶喆", "今天没回家 (Live)", "Soul Power (现场原音专辑)", 245, cand, false, 2)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != 0 {
		t.Errorf("同一场现场版不该吃 versionTags,实际 %d(%v)", p, terms)
	}
	if p := scoreTermPoints(terms, scoreTermTitleMatch); p != 120 {
		t.Errorf("精确同名应拿 120,实际 %d(%v)", p, terms)
	}
}

func TestScoreLyricCandidatePenalizesSingleEdit(t *testing.T) {

	lyr := "[00:49.45]placeholder line one\n[00:50.10]placeholder line two\n[00:50.95]placeholder line three\n[04:35.00]placeholder last line"
	local := struct{ artist, title, album string }{"PRINCE", "Diamonds and Pearls (2023 Remaster)", "Diamonds and Pearls (Remaster)"}
	edit := lyricCandidate{source: "kugou", lyrics: lyr, hasWordTiming: true, sourceReportedDurationSecs: 260,
		title: "Diamonds And Pearls (Edit)", artist: "Prince、The New Power Generation", album: "The Very Best Of Prince"}
	remaster := lyricCandidate{source: "qq", lyrics: lyr, hasWordTiming: true, sourceReportedDurationSecs: 282,
		title: "Diamonds and Pearls (2023 Remaster)", artist: "Prince/The New Power Generation", album: "Diamonds and Pearls (Remaster)"}
	if !versionTagsMismatch(local.title, local.album, edit.title, edit.album) {
		t.Fatalf("(Edit) 对 (2023 Remaster) 必须判成版本不符")
	}
	if versionTagsMismatch(local.title, local.album, remaster.title, remaster.album) {
		t.Fatalf("(2023 Remaster) 对 (2023 Remaster) 不该判成版本不符——remaster 不是另一次录音")
	}

	sEdit, termsEdit := scoreLyricCandidateDetailed(local.artist, local.title, local.album, 283.016, edit, false, 2)
	sRemaster, termsRemaster := scoreLyricCandidateDetailed(local.artist, local.title, local.album, 283.016, remaster, false, 0)
	if p := scoreTermPoints(termsEdit, scoreTermVersionTags); p != -600 {
		t.Errorf("(Edit) 候选应吃 versionTags -600,实际 %d(%v)", p, termsEdit)
	}
	if p := scoreTermPoints(termsEdit, scoreTermTitleMatch); p != 60 {
		t.Errorf("(Edit) 候选的标题吻合应降到剥括号档 60,实际 %d", p)
	}
	if p := scoreTermPoints(termsRemaster, scoreTermTitleMatch); p != 120 {
		t.Errorf("精确同名的 (2023 Remaster) 候选标题吻合应是 120,实际 %d", p)
	}
	if sEdit >= sRemaster {
		t.Errorf("剪辑版(%d)不该赢过精确同名的 2023 Remaster(%d)", sEdit, sRemaster)
	}
}

func TestDefaultVersionTagSemantics(t *testing.T) {

	if tags := titleVersionTags("Everybody Has An Aura (Album Version)"); len(tags) != 0 {
		t.Errorf("(Album Version) 不该再是版本限定词,实际 %v", tags)
	}
	if tags := titleVersionTags("妳和吉他 (album ver.)"); len(tags) != 0 {
		t.Errorf("(album ver.) 同理,实际 %v", tags)
	}

	if versionTagsMismatch("Everybody Has An Aura (Album Version)", "Rufus Featuring Chaka Khan",
		"Everybody Has An Aura", "Rufus Featuring Chaka Khan") {
		t.Error("本地 (Album Version) 对候选裸标题不该判版本不符")
	}
	if p := titleMatchTierPoints("Everybody Has An Aura", "Everybody Has An Aura (Album Version)"); p != 120 {
		t.Errorf("剥掉 (Album Version) 后是精确同名,标题档应为 120,实际 %d", p)
	}

	for _, c := range []struct{ cand string }{{"X (Single Version)"}, {"X (Edit)"}, {"X (Live)"}, {"X (Instrumental)"}} {
		if !versionTagsMismatch("X (Album Version)", "A", c.cand, "A") {
			t.Errorf("本地 (Album Version) 对候选 %s 仍应判版本不符", c.cand)
		}
	}

	if tags := titleVersionTags("Beat It (Single Version)"); !tags["single version"] || len(tags) != 1 {
		t.Errorf("(Single Version) 仍应是版本限定词,实际 %v", tags)
	}

	const jTitle, jAlbum = "Never Can Say Goodbye (Single Version)", "Michael: Songs From The Motion Picture"
	if !versionTagsMismatch(jTitle, jAlbum, "Never Can Say Goodbye", jAlbum) {
		t.Error("限定词层面本来就是对不上的(豁免走的是 sameRecording 那条路)")
	}
	if !sameRecordingDespiteVersionTags(jTitle, jAlbum, 180.8, "Never Can Say Goodbye", jAlbum, 180) {
		t.Error("时长 180.8 vs 180(0.4%)+ 同专辑,应判同一次录音")
	}

	if sameRecordingDespiteVersionTags(jTitle, jAlbum, 240, "Never Can Say Goodbye", jAlbum, 180) {
		t.Error("时长差 25% 不该豁免")
	}

	if sameRecordingDespiteVersionTags(jTitle, jAlbum, 180.8, "Never Can Say Goodbye", "Greatest Hits", 180) {
		t.Error("专辑无亲和不该豁免")
	}

	if !sameRecordingDespiteVersionTags("Rock With You", "HIStory", 219.9, "Rock with You (Single Version)", "HIStory", 219) {
		t.Error("候选独有 single version、时长吻合+同专辑,也该豁免")
	}

	if sameRecordingDespiteVersionTags("Burning Bridges (Acoustic)", "Native", 200, "Burning Bridges", "Native", 200) {
		t.Error("本地独有 acoustic 不该被豁免(第③门只认 sameRecordingNamingOnlyTags)")
	}
	if !sameRecordingDespiteVersionTags("Turn It Off", "Brand New Eyes", 259.7, "Turn It Off (Acoustic Version)", "Brand New Eyes", 259) {
		t.Error("候选多出 acoustic 仍应豁免(第④门的既有白名单)")
	}

	if sameRecordingDespiteVersionTags("X (Live)", "A", 200, "X", "A", 200) {
		t.Error("live 永不豁免")
	}
	if sameRecordingDespiteVersionTags("X", "A", 200, "X (Live)", "A", 200) {
		t.Error("live 永不豁免(反向)")
	}

	inVocab := map[string]bool{}
	for _, tag := range distinctRecordingVersionTags {
		inVocab[canonicalVersionTag(tag)] = true
	}
	for tag := range sameRecordingNamingOnlyTags {
		if !inVocab[tag] {
			t.Errorf("命名不对称白名单里的 %q 不在词表里", tag)
		}
	}
	for _, forbidden := range []string{"live", "demo", "instrumental", "remix", "edit", "karaoke"} {
		if sameRecordingNamingOnlyTags[forbidden] {
			t.Errorf("%q 绝不能进命名不对称白名单:沉默的一侧就是另一次录音", forbidden)
		}
	}

	lyr := "[00:10.00]placeholder one\n[00:12.00]placeholder two\n[00:14.00]placeholder three\n[02:59.00]placeholder last"
	cand := lyricCandidate{source: "qq", lyrics: lyr, hasWordTiming: true, sourceReportedDurationSecs: 180,
		title: "Never Can Say Goodbye", artist: "Jackson 5", album: jAlbum}
	_, terms := scoreLyricCandidateDetailed("Jackson 5", jTitle, jAlbum, 180.8, cand, false, 2)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != 0 {
		t.Errorf("同一次录音不该吃 versionTags,实际 %d(%v)", p, terms)
	}
}

func TestQualifierDeclaresCJKLive(t *testing.T) {
	segCases := []struct {
		in   string
		want bool
	}{

		{"晴天 (2004无与伦比演唱会)", true},
		{"Will You Be There (1992罗马尼亚布加勒斯特危险之旅演唱会)", true},
		{"稻香 (2018 CCTV-15音乐频道精彩音乐汇现场)", true},
		{"爱的初体验 (音乐会)", true},
		{"X - 2004演唱会", true},

		{"晴天 (演唱会主题曲)", false},
		{"女孩 (2015 韦礼安 《放开那女孩》 小巨蛋演唱会求爱主题曲/电视剧插曲)", false},

		{"我的滑板鞋演唱会", false},
		{"", false},
	}
	for _, c := range segCases {
		if got := qualifierDeclaresCJKLive(c.in); got != c.want {
			t.Errorf("qualifierDeclaresCJKLive(%q) = %v, want %v", c.in, got, c.want)
		}
	}

	if tags := recordingVersionTags("晴天 (2004无与伦比演唱会)", ""); !tags["live"] || len(tags) != 1 {
		t.Errorf("recordingVersionTags 应只多出 live,实际 %v", tags)
	}
	if tags := recordingVersionTags("晴天 (演唱会主题曲)", ""); len(tags) != 0 {
		t.Errorf("「(演唱会主题曲)」不该声明任何限定词,实际 %v", tags)
	}

	mismatchCases := []struct {
		name                 string
		localTitle, localAlb string
		candTitle, candAlb   string
		want                 bool
	}{
		{"同场:本地 (Live) vs 候选括号写演唱会", "稻香 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"稻香 (地表最强世界巡回演唱会)", "", false},
		{"真实:录音室本地 vs 酷我 1992 演唱会候选", "Will You Be There (Immortal Version)", "Immortal (Deluxe Edition)",
			"Will You Be There (1992罗马尼亚布加勒斯特危险之旅演唱会)", "", true},
		{"「(演唱会主题曲)」候选对录音室本地不算版本不符", "爱的初体验", "爱的初体验",
			"爱的初体验 (演唱会主题曲)", "", false},
	}
	for _, c := range mismatchCases {
		if got := versionTagsMismatch(c.localTitle, c.localAlb, c.candTitle, c.candAlb); got != c.want {
			t.Errorf("%s: versionTagsMismatch = %v, want %v(本地 %v / 候选 %v)", c.name, got, c.want,
				recordingVersionTags(c.localTitle, c.localAlb), recordingVersionTags(c.candTitle, c.candAlb))
		}
	}

	if got := liveIdentityTokens("Queen", "Save Me (Live In Montreal / November 1981)", ""); !got["montreal"] {
		t.Errorf("拉丁现场段的场馆词必须算进身份词,实际 %v", got)
	}
}

func TestLiveAlbumIdentityConflict(t *testing.T) {
	cases := []struct {
		name                           string
		artist, localTitle, localAlbum string
		candTitle, candAlbum           string
		want                           bool
	}{

		{"陈奕迅 Easy Ride vs Get A Life", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好 (Live)", "Get A Life (Live)", true},
		{"陈奕迅 Easy Ride vs 2003演唱会", "陈奕迅", "Shall We Talk (Live)", "The Easy Ride 演唱会 (Live)",
			"Shall We Talk (Live)", "2003演唱会", true},
		{"方大同 大事发声 vs Timeless演唱会", "方大同", "公园 (Live)", "大事发声.录音棚现场: 方大同 专场",
			"公园 (Live)", "Timeless演唱会", true},
		{"周杰伦 地表最强 vs 无与伦比2004", "周杰伦", "晴天 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"晴天 (Live)", "周杰伦 2004 无与伦比 演唱会 Live CD", true},

		{"同场:Easy Ride 网易云写法(共享 easy/ride)", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好(Live)", "The Easy Ride Live 陈奕迅演唱会", false},
		{"同场:15 香港演唱会 中英命名(共享 15/2011)", "Khalil Fong", "Rosy (Live)", "15 Khalil Fong Live in Hong Kong 2011",
			"Rosy (Live)", "15 香港演唱会(2011Live)", false},

		{"同场:歌手名粘连前缀", "周杰伦", "以父之名 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"以父之名 (Live)", "地表最强世界巡回演唱会", false},

		{"本地是录音室专辑的 bonus 现场曲", "Queen", "Save Me (Live In Montreal / November 1981)", "The Game (Deluxe Edition)",
			"Save Me (Live In Montreal / November 1981)", "Queen Rock Montreal", false},

		{"候选是录音室版", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好", "The Easy Ride", false},

		{"候选专辑为空且曲名只有 (Live)", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好 (Live)", "", false},

		{"v16 候选专辑空、场次在曲名括号里 → 冲突", "周杰伦", "稻香 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"稻香 (2018 CCTV-15音乐频道精彩音乐汇现场)", "", true},
		{"v16 同上 青花瓷", "周杰伦", "青花瓷 (Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"青花瓷 (2012CCTV-15音乐频道精彩音乐汇现场)", "", true},

		{"v16 候选专辑空、曲名括号场次与本地专辑共享年份 → 放行", "Khalil Fong", "Rosy (Live)", "15 Khalil Fong Live in Hong Kong 2011",
			"Rosy (2011 香港演唱会 Live)", "", false},

		{"v16 feat. 段不参与身份词", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好 (feat. 王菲) (Live)", "", false},

		{"v16 本地曲名括号里的场次也算本地身份词", "周杰伦", "晴天 (2004 无与伦比演唱会 Live)", "周杰伦地表最强世界巡回演唱会 (Live)",
			"晴天 (Live)", "周杰伦 2004 无与伦比 演唱会 Live CD", false},

		{"v16 候选专辑有身份词、曲名段共享 → 放行", "陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)",
			"活着多好 (Easy Ride Live)", "Get A Life (Live)", false},
	}
	for _, c := range cases {
		if got := liveAlbumIdentityConflict(c.artist, c.localTitle, c.localAlbum, c.candTitle, c.candAlbum); got != c.want {
			t.Errorf("%s: liveAlbumIdentityConflict(%q, %q, %q, %q, %q) = %v, want %v(本地身份词 %v / 候选身份词 %v)",
				c.name, c.artist, c.localTitle, c.localAlbum, c.candTitle, c.candAlbum, got, c.want,
				liveIdentityTokens(c.artist, c.localTitle, c.localAlbum), liveIdentityTokens(c.artist, c.candTitle, c.candAlbum))
		}
	}
}

func TestScoreLyricCandidatePenalizesOtherConcert(t *testing.T) {
	lyr := "[00:10.00]第一句现场歌词占位\n[00:20.00]第二句现场歌词占位\n[00:30.00]第三句现场歌词占位"
	wrongConcert := lyricCandidate{source: "kugou", lyrics: lyr,
		title: "活着多好 (Live)", album: "Get A Life (Live)"}
	rightConcert := lyricCandidate{source: "netease", lyrics: lyr,
		title: "活着多好(Live)", album: "The Easy Ride Live 陈奕迅演唱会"}
	sWrong, terms := scoreLyricCandidateDetailed("陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)", 0, wrongConcert, false, 0)
	sRight, _ := scoreLyricCandidateDetailed("陈奕迅", "活着多好 (Live)", "The Easy Ride 演唱会 (Live)", 0, rightConcert, false, 0)
	if p := scoreTermPoints(terms, scoreTermLiveAlbumConflict); p != -liveAlbumConflictPenalty {
		t.Errorf("另一场演唱会的候选应吃到 liveAlbumConflict %d,实际 %d", -liveAlbumConflictPenalty, p)
	}
	if sWrong >= sRight {
		t.Errorf("其余条件对齐时,另一场演唱会的候选(%d)不该赢过吻合场次的候选(%d)", sWrong, sRight)
	}
}

func TestSameRecordingDespiteVersionTags(t *testing.T) {
	localTitle, localAlbum, localDur := "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373
	cases := []struct {
		name                 string
		candTitle, candAlbum string
		candDur              float64
		want                 bool
	}{
		{"孤独探戈真实案例:acoustic 演奏方式标注", "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, true},

		{"时长差 7.6% 的错场次", "孤独探戈 (Live)", "Get A Life (Live)", 233.081, false},

		{"候选缺 Live 标记", "孤独探戈", "The Easy Ride", 215.4, false},

		{"伴奏版时长相同也不豁免", "孤独探戈 (伴奏)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, false},

		{"国语版时长相同也不豁免", "孤独探戈 (国语)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4, false},

		{"专辑对不上", "孤独探戈(Acoustic Piano)(Live)", "完全无关的专辑", 215.4, false},

		{"没自报时长", "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 0, false},
	}
	for _, c := range cases {
		if got := sameRecordingDespiteVersionTags(localTitle, localAlbum, localDur, c.candTitle, c.candAlbum, c.candDur); got != c.want {
			t.Errorf("%s: sameRecordingDespiteVersionTags(...%q/%q/%.1f) = %v, want %v",
				c.name, c.candTitle, c.candAlbum, c.candDur, got, c.want)
		}
	}

	if sameRecordingDespiteVersionTags(localTitle, localAlbum, 0, "孤独探戈(Acoustic Piano)(Live)", "The Easy Ride Live 陈奕迅演唱会", 215.4) {
		t.Error("本地时长未知时不该豁免")
	}
}

func TestScoreLyricCandidateWaivesVersionTagsForSameRecording(t *testing.T) {
	lyr := "[00:13.33]你可知道石头\n[00:16.84]要几多冷汗才被冲走\n[00:20.57]你早知探戈"
	waived := lyricCandidate{source: "netease", lyrics: lyr,
		title: "孤独探戈(Acoustic Piano)(Live)", album: "The Easy Ride Live 陈奕迅演唱会",
		sourceReportedDurationSecs: 215.4}
	_, terms := scoreLyricCandidateDetailed("陈奕迅", "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373, waived, false, 0)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != 0 {
		t.Errorf("时长锚定坐实同一次录音时,versionTags 应被豁免,实际 %+d", p)
	}
	notAnchored := waived
	notAnchored.sourceReportedDurationSecs = 233.081
	_, terms = scoreLyricCandidateDetailed("陈奕迅", "孤独探戈 (Live)", "The Easy Ride 演唱会 (Live)", 215.373, notAnchored, false, 0)
	if p := scoreTermPoints(terms, scoreTermVersionTags); p != -versionMismatchPenalty {
		t.Errorf("时长不吻合时 versionTags 应照扣 %d,实际 %+d", -versionMismatchPenalty, p)
	}
}

func TestVersionTagsMismatch(t *testing.T) {
	cases := []struct {
		label      string
		local      string
		localAlbum string
		candidate  string
		candAlbum  string
		wantMismat bool
	}{

		{"正式版 vs Original Version", "Blue Gangsta", "", "Blue Gangsta (Original Version)", "", true},
		{"正式版 vs Demo", "Beat It", "", "Beat It (Demo)", "", true},
		{"正式版 vs Live", "Billie Jean", "", "Billie Jean (Live)", "", true},

		{"Demo vs 正式版", "Beat It (Demo)", "", "Beat It", "", true},
		{"Original Version vs 正式版", "Blue Gangsta (Original Version)", "", "Blue Gangsta", "", true},

		{"两边都是 Live", "Billie Jean (Live)", "", "Billie Jean [Live]", "", false},
		{"两边都干净", "Blue Gangsta", "", "Blue Gangsta", "", false},

		{"正式版 vs Remastered", "Thriller", "", "Thriller (2001 Remastered)", "", false},
		{"正式版 vs Deluxe", "Bad", "", "Bad (Deluxe Edition)", "", false},

		{"候选歌名为空", "Blue Gangsta", "", "", "", false},
		{"候选歌名只有空白", "Blue Gangsta", "", "   ", "", false},

		{"Live and Let Die 不是 live 版", "Live and Let Die", "", "Live and Let Die", "", false},

		{"正式版 vs 伴奏", "蜗牛 (伴奏)", "", "蜗牛", "", true},
		{"两边都是伴奏", "蜗牛 (伴奏)", "", "蜗牛 (伴奏)", "", false},
		{"不插电的夏天 不是不插电版", "不插电的夏天", "", "不插电的夏天", "", false},

		{
			"歌名干净但专辑是现场版", "1999", "The Hits/The B-Sides",
			"1999", "Nude Tour, 1990 (Remastered, Live On Broadcasting)", true,
		},

		{
			"专辑对得上(连字符写法)", "1999", "The Hits/The B-Sides",
			"1999", "The Hits-The B-Sides", false,
		},

		{"合集 vs 原始专辑", "1999", "The Hits/The B-Sides", "1999", "1999", false},

		{
			"限定词一个写歌名一个写专辑", "Layla (Acoustic)", "",
			"Layla", "Unplugged (Acoustic)", false,
		},

		{
			"已知缺口:专辑名里的裸词限定词抓不到", "Come As You Are", "MTV Unplugged in New York",
			"Come As You Are", "Nevermind", false,
		},

		{
			"专辑写 Remastered 不算版本差异", "Thriller", "Thriller",
			"Thriller", "Thriller (2001 Remastered Edition)", false,
		},

		{"专辑名裸词 Alive 不算 live", "Song", "Alive", "Song", "Some Album", false},

		{"候选元数据全空", "Blue Gangsta", "Bad", "", "", false},
	}
	for _, c := range cases {
		got := versionTagsMismatch(c.local, c.localAlbum, c.candidate, c.candAlbum)
		if got != c.wantMismat {
			t.Errorf("%s: versionTagsMismatch(%q/%q, %q/%q) = %v, want %v",
				c.label, c.local, c.localAlbum, c.candidate, c.candAlbum, got, c.wantMismat)
		}
	}
}

func TestScoreLyricCandidatePenalizesWrongVersion(t *testing.T) {
	lrc := "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n"
	base := lyricCandidate{source: "kugou", lyrics: lrc, hasWordTiming: true, wordTimingYRC: "x"}
	good := base
	good.title = "Blue Gangsta"
	bad := base
	bad.title = "Blue Gangsta (Original Version)"

	gs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, good, false, 0)
	bs := scoreLyricCandidate("Michael Jackson", "Blue Gangsta", "", 9, bad, false, 0)
	if gs <= bs {
		t.Errorf("标题吻合的候选(%d)必须高于版本对不上的候选(%d)", gs, bs)
	}
	if bs < 1 {
		t.Errorf("扣分后仍要留至少 1 分(只有这一个候选时有总比没有好),实际 %d", bs)
	}
	if gs-bs < 400 {
		t.Errorf("差距要足够决定性,实际只差 %d 分", gs-bs)
	}
}

func TestLyricTitleAccepted(t *testing.T) {
	cases := []struct {
		label           string
		candidate, want string
		accept          bool
	}{
		{"完全一致", "In My Room", "In My Room", true},
		{"候选没有版本后缀:去括号后相等,认",
			"In My Room", "In My Room (Remastered 2014)", true},
		{"本地没有、候选有:同理", "In My Room (Remastered 2014)", "In My Room", true},
		{"两边括号内容不同但主名相同:认(真正的版本差异交给 versionTagsMismatch 拦)",
			"Hello (Live)", "Hello (Studio)", true},
		{"括号完全一致", "In My Room (Remastered 2014)", "In My Room (Remastered 2014)", true},
		{"大小写/空格不算差异", "never let go (remastered 2014)", "Never Let Go (Remastered 2014)", true},
		{"根本是两首歌", "First Love", "In My Room", false},

		{"子串:候选是本地的前缀,不认", "Real Love", "Real Love Baby", false},
		{"子串:本地是候选的前缀,不认", "Real Love Baby", "Real Love", false},
		{"子串:短词命中长曲名,不认", "Love", "Real Love", false},
		{"空串两侧都不认", "", "In My Room", false},

		{"双语后缀:候选带英文别名,认", "起源 Origin", "起源", true},
		{"双语后缀:反向(本地带别名),认", "起源", "起源 Origin", true},
		{"双语后缀 + 括号叠加,认", "起源 Origin (Live)", "起源", true},

		{"纯英文前缀关系仍不认(Love/Love Song 是两首歌)", "Love Song", "Love", false},
		{"尾巴带数字不认(起源2 是另一首歌)", "起源2", "起源", false},
		{"尾巴含汉字不认(起源之战 是另一首歌)", "起源之战", "起源", false},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.want); got != c.accept {
			t.Errorf("%s: lyricTitleAccepted(%q, %q) = %v, want %v",
				c.label, c.candidate, c.want, got, c.accept)
		}
	}
	if lyricTitleAccepted("In My Room", "") {
		t.Error("本地标题为空不该认")
	}
}

func TestScoringAfter20260809Review(t *testing.T) {
	const dur = 200.0

	good := "[00:00.00]a\n" + strings.Repeat("[00:10.00]x\n", 47) + "[03:20.00]end"

	t.Run("来源不再加分", func(t *testing.T) {
		var scores []int
		for _, src := range []string{"netease", "qq", "kugou", "musixmatch", "lrclib"} {
			s, terms := scoreLyricCandidateDetailed(
				"someone", "song", "", dur, lyricCandidate{source: src, lyrics: good}, false, 0)
			scores = append(scores, s)
			for _, term := range terms {
				if term.Kind == scoreTermSource {
					t.Errorf("%s 仍然带着来源加分 %d", src, term.Points)
				}
			}
		}
		for i := 1; i < len(scores); i++ {
			if scores[i] != scores[0] {
				t.Errorf("同一份歌词换个来源分数就变了: %v —— 来源不该再影响分数", scores)
				break
			}
		}
	})

	t.Run("时长不符改成重扣而不是一票否决", func(t *testing.T) {

		off := "[00:00.00]a\n[00:30.00]b\n[01:00.00]c"
		score, terms := scoreLyricCandidateDetailed(
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: off}, false, 0)
		if score < 0 {
			t.Fatalf("时长不符不该再判 -1(会被整条丢弃),实际 %d", score)
		}
		var penalized bool
		for _, term := range terms {
			if term.Kind == scoreTermDurationOff {
				penalized = true
				if term.Points >= 0 {
					t.Errorf("时长不符那一项应该是扣分,实际 %+d", term.Points)
				}
			}
		}
		if !penalized {
			t.Error("没有记下「时长不符」这一项,用户就看不到它为什么排在后面")
		}

		ok, _ := scoreLyricCandidateDetailed(
			"someone", "song", "", dur, lyricCandidate{source: "lrclib", lyrics: good}, false, 0)
		if score >= ok {
			t.Errorf("时长不符的候选(%d)不该压过时长吻合的(%d)", score, ok)
		}
	})

	t.Run("硬拒绝只留真的不能用的那几种", func(t *testing.T) {

		if s, _ := scoreLyricCandidateDetailed(
			"someone", "song", "", dur, lyricCandidate{source: "qq", lyrics: "just words\nno timestamps"}, false, 0); s != -1 {
			t.Errorf("没有时间戳的歌词仍应判 -1,实际 %d", s)
		}
	})
}

func TestSearchTitleVariants(t *testing.T) {
	cases := []struct {
		label string
		title string
		want  []string
	}{
		{"没有括号:只有一条,不做无谓的重复请求", "Automatic", []string{"Automatic"}},
		{"噪音括号:裸标题优先,原样作兜底",
			"Automatic (Remastered 2014)", []string{"Automatic", "Automatic (Remastered 2014)"}},
		{"方括号同样算", "Hold My Hand [feat. Akon]",
			[]string{"Hold My Hand", "Hold My Hand [feat. Akon]"}},
		{"整个标题都在括号里:剥完是空的,不能生成一条空查询",
			"(Untitled)", []string{"(Untitled)"}},
		{"空标题", "", []string{""}},

		{"版本限定词:原样优先",
			"Billie Jean (Single Version)",
			[]string{"Billie Jean (Single Version)", "Billie Jean"}},
		{"live 同理", "Hello (Live)", []string{"Hello (Live)", "Hello"}},
		{"remaster 不算另一次录音,该去括号",
			"Hello (Remastered 2015)", []string{"Hello", "Hello (Remastered 2015)"}},
		{"破折号写法的版本限定词也认", "Hello - Live at Wembley",
			[]string{"Hello - Live at Wembley"}},
	}
	for _, c := range cases {
		got := searchTitleVariants(c.title)
		if len(got) != len(c.want) {
			t.Errorf("%s: searchTitleVariants(%q) = %q, want %q", c.label, c.title, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: searchTitleVariants(%q)[%d] = %q, want %q",
					c.label, c.title, i, got[i], c.want[i])
			}
		}
	}
}

func TestSearchTitleVariantsAlwaysKeepsBothForms(t *testing.T) {
	for _, title := range []string{
		"Automatic (Remastered 2014)",
		"Billie Jean (Single Version)",
		"Blue Gangsta (Original Version)",
	} {
		got := searchTitleVariants(title)
		if len(got) != 2 {
			t.Errorf("%q 该有两条查询, got %q", title, got)
			continue
		}
		if got[0] == got[1] {
			t.Errorf("%q 两条查询不该重复: %q", title, got)
		}
		bare, raw := false, false
		for _, q := range got {
			if q == title {
				raw = true
			}
			if q == stripParens(title) {
				bare = true
			}
		}
		if !raw || !bare {
			t.Errorf("%q 的查询序列必须同时含原样和裸标题, got %q", title, got)
		}
	}
}

func TestQQSearchQueries(t *testing.T) {
	got := qqSearchQueries("宇多田ヒカル", "Automatic (Remastered 2014)")
	want := []string{"宇多田ヒカル Automatic", "宇多田ヒカル Automatic (Remastered 2014)"}
	if len(got) != len(want) {
		t.Fatalf("qqSearchQueries = %q, want %q", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("qqSearchQueries[%d] = %q, want %q", i, got[i], want[i])
		}
	}

	if q := qqSearchQueries("", "Automatic"); len(q) != 1 || q[0] != "Automatic" {
		t.Errorf("歌手名为空: qqSearchQueries = %q, want [Automatic]", q)
	}
}

func lrcEndingAt(lastSecs int, lines int) string {
	var b strings.Builder
	step := lastSecs / lines
	if step < 1 {
		step = 1
	}
	for i := 0; i < lines; i++ {
		t := i * step
		if i == lines-1 {
			t = lastSecs
		}

		fmt.Fprintf(&b, "[%02d:%02d.00]this is lyric line number %d\n", t/60, t%60, i)
	}
	return b.String()
}

func TestCorroborationYieldsToAWellFittingCandidate(t *testing.T) {
	const dur = 237.0
	shortA := lyricCandidate{source: "qq", lyrics: lrcEndingAt(143, 40)}
	shortB := lyricCandidate{source: "kugou", lyrics: lrcEndingAt(143, 40)}
	fits := lyricCandidate{source: "lrclib", lyrics: lrcEndingAt(226, 44)}

	corr := corroboratedEndings([]lyricCandidate{shortA, shortB, fits}, dur)
	if len(corr) != 0 {
		t.Errorf("有候选时长吻合时不该再发印证豁免, got %v", corr)
	}
	qqScore, qqTerms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr[shortA.source], 0)
	lrcScore, _ := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, fits, corr[fits.source], 0)
	for _, term := range qqTerms {
		if term.Kind == scoreTermCorroborated {
			t.Error("抓错版本的候选不该再拿到 corroborated 加分")
		}
	}
	if lrcScore <= qqScore {
		t.Errorf("时长吻合的候选该赢: lrclib %d vs qq %d", lrcScore, qqScore)
	}

	corr2 := corroboratedEndings([]lyricCandidate{shortA, shortB}, dur)
	if !corr2[shortA.source] || !corr2[shortB.source] {
		t.Errorf("所有源都提前结束时,印证豁免必须保留(长尾奏的歌全靠它), got %v", corr2)
	}
	if _, terms := scoreLyricCandidateDetailed("Daniel Caesar", "Valentina", "", dur, shortA, corr2[shortA.source], 0); !hasTerm(terms, scoreTermCorroborated) {
		t.Error("这一档该走 corroborated 加分")
	}

	if corr3 := corroboratedEndings([]lyricCandidate{shortA, shortB, fits}, 0); !corr3[shortA.source] {
		t.Errorf("时长未知时不该收紧, got %v", corr3)
	}
}

func hasTerm(terms []scoreTerm, kind string) bool {
	for _, t := range terms {
		if t.Kind == kind {
			return true
		}
	}
	return false
}

func TestTitleMatchTierPoints(t *testing.T) {
	cases := []struct {
		name        string
		cand, local string
		want        int
	}{
		{"精确同名", "月食", "月食", 120},
		{"大小写与空白不敏感", "Blue  Gangsta", "blue gangsta", 120},
		{"feat 噪音括号升回精确档", "Song (feat. Rick Ross)", "Song", 120},
		{"版本括号只到括号档", "Song (Live)", "Song", 60},
		{"中英双语同名", "起源 Origin", "起源", 30},
		{"完全不同的歌名", "Another Tune", "Song", 0},
		{"候选没报标题", "", "Song", 0},

		{"中文版本括号只到括号档(伴奏)", "蜗牛 (伴奏)", "蜗牛", 60},
		{"中文版本括号只到括号档(伴奏版,词元被粘连)", "蜗牛 (伴奏版)", "蜗牛", 60},
	}
	for _, c := range cases {
		if got := titleMatchTierPoints(c.cand, c.local); got != c.want {
			t.Errorf("%s: titleMatchTierPoints(%q, %q) = %d, want %d", c.name, c.cand, c.local, got, c.want)
		}
	}
}

func TestAlbumAffinityTerm(t *testing.T) {
	lyr := "[00:10.00]first real line here\n[00:20.00]second real line here\n[00:30.00]third real line here"
	find := func(terms []scoreTerm, kind string) int {
		for _, tm := range terms {
			if tm.Kind == kind {
				return tm.Points
			}
		}
		return 0
	}

	_, terms := scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr, album: "实况电影"}, false, 0)
	if got := find(terms, scoreTermAlbum); got != 150 {
		t.Errorf("专辑完全一致应 +150,实际 %+d", got)
	}

	_, terms = scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr}, false, 0)
	if got := find(terms, scoreTermAlbum); got != 0 {
		t.Errorf("候选专辑缺失应是零证据(0),实际 %+d", got)
	}

	_, terms = scoreLyricCandidateDetailed("someone", "song", "实况电影", 0,
		lyricCandidate{source: "qq", lyrics: lyr, album: "Totally Different"}, false, 0)
	if got := find(terms, scoreTermAlbum); got < 0 {
		t.Errorf("专辑亲和是 bonus-only,不该扣分,实际 %+d", got)
	}
}

func TestContentConsensusFamilyDoesNotDoubleCount(t *testing.T) {
	same := "[00:01.00]this is the same lyric line one\n[00:05.00]and the very same line two here\n[00:09.00]closing line of the song text"
	cands := []lyricCandidate{
		{source: "deezer", lyrics: same},
		{source: "lyricfind", lyrics: same},
		{source: "lrclib", lyrics: same},
	}
	peers := contentConsensusPeers("someone", "song", cands, 0)

	for _, src := range []string{"deezer", "lyricfind"} {
		if len(peers[src]) != 1 || peers[src][0] != "lrclib" {
			t.Errorf("%s 的独立互证对象应当只有 lrclib,实际 %v", src, peers[src])
		}
	}

	if len(peers["lrclib"]) != 1 {
		t.Errorf("lrclib 只该拿到 1 家独立印证(deezer/lyricfind 同属 LyricFind),实际 %v", peers["lrclib"])
	}

	cands = append(cands, lyricCandidate{source: "qq", lyrics: same})
	peers = contentConsensusPeers("someone", "song", cands, 0)
	if len(peers["lrclib"]) != 2 {
		t.Errorf("加入真正独立的 qq 之后 lrclib 该有 2 家独立印证,实际 %v", peers["lrclib"])
	}
	if len(peers["deezer"]) != 2 {
		t.Errorf("deezer 该看到 lrclib + qq 两家,实际 %v", peers["deezer"])
	}
}

func TestLyricSourceConsensusFamily(t *testing.T) {
	if lyricSourceConsensusFamily(lyricSourceDeezer) != lyricSourceConsensusFamily(lyricSourceLyricFind) {
		t.Error("deezer 与 lyricfind 必须归同一家 —— 两者的正文都由 LyricFind 供")
	}
	for _, s := range []string{lyricSourceNetease, lyricSourceQQ, lyricSourceKugou,
		lyricSourceMusixmatch, lyricSourceLRCLIB, lyricSourceAMLL, lyricSourceKuwo, lyricSourceMigu} {
		if lyricSourceConsensusFamily(s) != s {
			t.Errorf("%s 应当自成一家,实际归到 %q", s, lyricSourceConsensusFamily(s))
		}
	}
}

func TestContentConsensusPeers(t *testing.T) {
	same := "[00:01.00]this is the same lyric line one\n[00:05.00]and the very same line two here\n[00:09.00]closing line of the song text"
	diff := "[00:01.00]completely different words entirely\n[00:05.00]nothing shared with the others\n[00:09.00]another unrelated closing line"
	cands := []lyricCandidate{
		{source: "netease", lyrics: same},
		{source: "qq", lyrics: same},
		{source: "kugou", lyrics: diff},
	}
	peers := contentConsensusPeers("someone", "song", cands, 0)
	if len(peers["netease"]) != 1 || len(peers["qq"]) != 1 {
		t.Errorf("内容一致的两源应互为 peer(各 1),实际 netease=%v qq=%v", peers["netease"], peers["qq"])
	}

	if len(peers["netease"]) != 1 || peers["netease"][0] != "qq" {
		t.Errorf("netease 的互证对象应当是 qq,实际 %v", peers["netease"])
	}
	if len(peers["qq"]) != 1 || peers["qq"][0] != "netease" {
		t.Errorf("qq 的互证对象应当是 netease,实际 %v", peers["qq"])
	}
	if len(peers["kugou"]) != 0 {
		t.Errorf("内容孤立的源 peers 应为空,实际 %v", peers["kugou"])
	}

	diffFits := "[00:01.00]completely different words entirely\n[00:50.00]nothing shared with the others\n[01:38.00]another unrelated closing line"
	cands2 := []lyricCandidate{
		{source: "netease", lyrics: same},
		{source: "qq", lyrics: same},
		{source: "lrclib", lyrics: diffFits},
	}
	peers2 := contentConsensusPeers("someone", "song", cands2, 100)
	if len(peers2["netease"]) != 0 || len(peers2["qq"]) != 0 {
		t.Errorf("存在时长吻合候选时,时长不吻合的候选不该领共识分,实际 netease=%v qq=%v", peers2["netease"], peers2["qq"])
	}

	lyr := "[00:10.00]first real line here\n[00:20.00]second real line here\n[00:30.00]third real line here"
	s2, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 2)
	s1, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 1)
	s0, _ := scoreLyricCandidateDetailed("someone", "song", "", 0, lyricCandidate{source: "qq", lyrics: lyr}, false, 0)
	if s2-s0 != 250 || s1-s0 != 150 {
		t.Errorf("共识分档位不对: peers2-peers0=%d(want 250), peers1-peers0=%d(want 150)", s2-s0, s1-s0)
	}
}

func TestUsableValueAdd(t *testing.T) {
	main := "[00:01.00]la la la one\n[00:02.00]lo lo lo two\n[00:03.00]le le le three\n[00:04.00]li li li four"
	trFull := "[00:01.00]中文一\n[00:02.00]中文二\n[00:03.00]中文三\n[00:04.00]中文四"
	trSparse := "[00:01.00]中文一\n[00:02.00]中文二\nx\ny\nz\nw"
	kanaMain := "[00:01.00]ひかりのなか one\n[00:02.00]こころのうた two\n[00:03.00]そらとうみが three"
	roma := "[00:01.00]hikari no naka\n[00:02.00]kokoro no uta\n[00:03.00]sora to umi ga"

	if tr, _ := usableValueAdd(main, trFull, "zh", "", "zh"); !tr {
		t.Error("覆盖全的中文译文配英文原文应判可用")
	}
	if tr, _ := usableValueAdd(main, trFull, "zh", "", "en"); tr {
		t.Error("目标语言 en 时中文译文不该判可用")
	}
	if tr, _ := usableValueAdd(main, trSparse, "zh", "", "zh"); tr {
		t.Error("覆盖不过半的译文不该判可用")
	}
	if tr, _ := usableValueAdd(trFull, trFull, "zh", "", "zh"); tr {
		t.Error("原文本身是中文(cjk>0.5)时不需要中文译文,不该加分")
	}
	if _, rm := usableValueAdd(kanaMain, "", "", roma, "zh"); !rm {
		t.Error("日文形态歌词配带时间轴罗马音应判可用")
	}
	if _, rm := usableValueAdd(main, "", "", roma, "zh"); rm {
		t.Error("非日文歌词的\"罗马音\"没有增值,不该判可用")
	}
}

func TestOvershootPenalty(t *testing.T) {
	dur := 100.0

	over := "[00:01.00]aaa bbb ccc\n[01:50.00]ddd eee fff\n[01:55.00]ggg hhh iii"
	find := func(terms []scoreTerm, kind string) (int, bool) {
		for _, tm := range terms {
			if tm.Kind == kind {
				return tm.Points, true
			}
		}
		return 0, false
	}

	_, terms := scoreLyricCandidateDetailed("someone", "song", "", dur,
		lyricCandidate{source: "qq", lyrics: over}, true, 0)
	if p, ok := find(terms, scoreTermDurationOvershoot); !ok || p != -700 {
		t.Errorf("overshoot 应记独立项 -700,实际 %+d (present=%v)", p, ok)
	}
	if _, ok := find(terms, scoreTermCorroborated); ok {
		t.Error("overshoot 候选不该再拿到印证豁免那一项")
	}
}

func TestParenVersionTagsWordBoundary(t *testing.T) {

	for _, title := range []string{"Song (feat. Oliver Tree)", "Song (feat. Demons)", "Song (with Akon)"} {
		if tags := parenOnlyVersionTags(title); len(tags) != 0 {
			t.Errorf("%q 的括号是纯噪音,不该抽出版本词,实际 %v", title, tags)
		}
		if got := titleMatchTierPoints("Song", title); got != 120 {
			t.Errorf("%q 对裸标题候选应升回精确档 120,实际 %d", title, got)
		}
	}

	for _, title := range []string{"Song (Live)", "Song (Acoustic Version)", "Song (Radio Edit)"} {
		if tags := parenOnlyVersionTags(title); len(tags) == 0 {
			t.Errorf("%q 的括号是真版本词,应该抽出来", title)
		}
	}
}

func TestUsableTranslationLanguageAndJapanese(t *testing.T) {
	main := "[00:01.00]one two three\n[00:02.00]four five six\n[00:03.00]seven eight nine\n[00:04.00]ten eleven twelve"
	trZh := "[00:01.00]中文一\n[00:02.00]中文二\n[00:03.00]中文三\n[00:04.00]中文四"

	if tr, _ := usableValueAdd(main, trZh, "zh", "", "zh-hans"); !tr {
		t.Error("trLang=zh 与 targetLang=zh-hans 是同一种语言,应判可用")
	}

	jaMain := "[00:01.00]桜流し 春の空\n[00:02.00]記憶の海 深く沈む\n[00:03.00]永遠の夢 見果てぬまま\n[00:04.00]君の声 遠く響く"
	if cjkRatio(jaMain) <= 0.5 {
		t.Skipf("测试样本汉字占比 %.2f 未达 0.5,构造不出该场景", cjkRatio(jaMain))
	}
	if tr, _ := usableValueAdd(jaMain, trZh, "zh", "", "zh"); !tr {
		t.Error("汉字密集的日文原文配中文译文应判可用(kana 占比已排除中文原文)")
	}

	if tr, _ := usableValueAdd(trZh, trZh, "zh", "", "zh"); tr {
		t.Error("纯中文原文不需要中文译文,不该加分")
	}
}

func TestConsensusDeniedToOvershoot(t *testing.T) {

	long := "[00:01.00]same wrong version line one\n[01:30.00]same wrong version line two\n[02:30.00]same wrong version line three"
	cands := []lyricCandidate{
		{source: "qq", lyrics: long},
		{source: "kugou", lyrics: long},
	}
	peers := contentConsensusPeers("someone", "song", cands, 100)
	if len(peers["qq"]) != 0 || len(peers["kugou"]) != 0 {
		t.Errorf("overshoot 候选不该领跨源共识分,实际 qq=%v kugou=%v", peers["qq"], peers["kugou"])
	}
}

func TestLyricsUpgradeBaselineAcrossScoringVersions(t *testing.T) {
	const oldLyrics = "[00:01.00]stored line one\n[00:02.00]stored line two\n[00:03.00]stored line three"
	e := enrichEntry{
		Lyrics:               oldLyrics,
		LyricsSource:         "kugou",
		LyricsScore:          549,
		LyricsScoringVersion: 2,
	}
	scored := []scoredLyricCandidateResult{
		{Source: "netease", Lyrics: "[00:01.00]other", Score: 700},
		{Source: "kugou", Lyrics: oldLyrics, Score: 880},
	}

	if base, ok := lyricsUpgradeBaseline(e, scored); !ok || base != 880 {
		t.Errorf("跨版本应改用同一份歌词的本轮分 880 作基准,实际 base=%d ok=%v", base, ok)
	}

	if _, ok := lyricsUpgradeBaseline(e, scored[:1]); ok {
		t.Error("现存歌词不在本轮候选里时应判为不可比,交给 rescore 收编")
	}

	e.LyricsScoringVersion = lyricsScoringVersion
	if base, ok := lyricsUpgradeBaseline(e, scored); !ok || base != 549 {
		t.Errorf("同版本应直接用存量分 549,实际 base=%d ok=%v", base, ok)
	}
}

func TestApplyWordTimingTitleOverride_RealWorldCase(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 944, Title: "公园 (Live)", Album: "Timeless演唱会",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermDuration, Points: 170},
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermLines, Points: 64},
				{Kind: scoreTermTitleMatch, Points: 60},
				{Kind: scoreTermConsensus, Points: 250},
			},
		},
		{
			Source: "netease", Score: 674, Title: "公园 (Live版)", Album: "方大同·专场",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermDuration, Points: 169},
				{Kind: scoreTermLines, Points: 60},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 120},
				{Kind: scoreTermConsensus, Points: 250},
			},
		},
	}
	applyWordTimingTitleOverride(results)

	kugou, netease := &results[0], &results[1]
	if kugou.Score != 544 {
		t.Errorf("酷狗的逐字加分应被整段撤销:944-400=544,实际 %d", kugou.Score)
	}
	if p := scoreTermPoints(kugou.ScoreTerms, scoreTermWordTimingOverride); p != -400 {
		t.Errorf("应该多出一条 wordTimingOverride:-400,实际 %d", p)
	}
	if netease.Score != 674 {
		t.Errorf("网易云不该被这条规则动到,实际 %d", netease.Score)
	}

	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if results[0].Source != "netease" {
		t.Errorf("修复后冠军应该是 netease(674 > 544),实际是 %s", results[0].Source)
	}
}

func TestApplyWordTimingTitleOverride_SecondRealWorldCase(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 1059,
			Title: "Shake Your Body (Remastered Single Version)", Album: "Michael Jackson's This Is It",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 60},
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 60},
				{Kind: scoreTermDuration, Points: 214},
			},
		},
		{
			Source: "musixmatch", Score: 825,
			Title: "Shake Your Body (Down to the Ground) [Single Version]",
			Album: "Michael Jackson's This Is It (The Music That Inspired the Movie)",
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 120},
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 90},
				{Kind: scoreTermDuration, Points: 215},
			},
		},
	}
	applyWordTimingTitleOverride(results)
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if results[0].Source != "musixmatch" {
		t.Errorf("修复后冠军应该是 musixmatch(标题/专辑都更吻合),实际是 %s", results[0].Source)
	}
}

func TestApplyWordTimingTitleOverride_DoesNotFireWhenTitleDoesNotFavorRunnerUp(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 400 + 75 + 120,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 75},
				{Kind: scoreTermTitleMatch, Points: 120},
			},
		},
		{
			Source: "netease", Score: 150 + 120,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 120},
			},
		},
	}
	before := results[0].Score
	applyWordTimingTitleOverride(results)
	if results[0].Score != before {
		t.Errorf("标题吻合分相等(不是亚军严格更高)时不该触发撤销,分数从 %d 变成了 %d", before, results[0].Score)
	}
}

func TestApplyWordTimingTitleOverride_NoOpWithoutWordTiming(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "netease", Score: 900, ScoreTerms: []scoreTerm{{Kind: scoreTermAlbum, Points: 150}, {Kind: scoreTermTitleMatch, Points: 120}}},
		{Source: "qq", Score: 500, ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: 500}}},
	}
	applyWordTimingTitleOverride(results)
	if results[0].Score != 900 || len(results[0].ScoreTerms) != 2 {
		t.Error("冠军没有 wordTiming 加分时,函数不该动任何分数或加任何新 term")
	}
}

func TestApplyWordTimingTitleOverride_NoOpWhenWordTimingNotDecisive(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{
			Source: "kugou", Score: 1200,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermAlbum, Points: 150},
				{Kind: scoreTermTitleMatch, Points: 30},
				{Kind: scoreTermConsensus, Points: 250},
				{Kind: scoreTermLines, Points: 370},
			},
		},
		{
			Source: "netease", Score: 600,
			ScoreTerms: []scoreTerm{{Kind: scoreTermTitleMatch, Points: 120}},
		},
	}
	before := results[0].Score
	applyWordTimingTitleOverride(results)
	if results[0].Score != before {
		t.Errorf("去掉逐字加分冠军依然是冠军(800>600)时不该触发,分数从 %d 变成了 %d", before, results[0].Score)
	}
}

func TestApplyWordTimingTitleOverride_SkipsRejectedCandidates(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "lrclib", Score: -1, Instrumental: true},
		{
			Source: "kugou", Score: 500,
			ScoreTerms: []scoreTerm{
				{Kind: scoreTermWordTiming, Points: 400},
				{Kind: scoreTermTitleMatch, Points: 30},
			},
		},
		{Source: "musixmatch", Score: -1, ScoreTerms: []scoreTerm{{Kind: scoreRejectNotTimed}}},
	}
	applyWordTimingTitleOverride(results)
	if results[1].Score != 500 {
		t.Errorf("只有一个真实候选、没有亚军可比时不该触发,分数从 500 变成了 %d", results[1].Score)
	}
	if results[0].Score != -1 || results[2].Score != -1 {
		t.Error("一票否决/纯音乐标记的分数不该被这条规则改动")
	}
}

func TestIsProbablyWrongLanguageLyrics(t *testing.T) {
	chineseLyrics := "[00:13.76]在他的墨鏡裡\n[00:16.38]看不到二泉的月映有多麼朦朧\n[00:21.77]只記得少年時"
	englishLyrics := "[00:00.10]this is an english lyric line\n[00:03.20]another english line here today"

	cases := []struct {
		name                                             string
		localArtist, localTitle, candidateArtist, lyrics string
		want                                             bool
	}{
		{
			name:        "罗马化标签+候选源确认的中文歌手名→不拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "方大同",
			lyrics: chineseLyrics, want: false,
		},
		{

			name:        "罗马化标签在手工别名表里能查到中文名(洪佩瑜真实残留案例)→不拦,即使候选源没给中文名",
			localArtist: "Pei-yu Hung", localTitle: "Some Song", candidateArtist: "",
			lyrics: chineseLyrics, want: false,
		},
		{

			name:        "罗马化标签+候选源没给出歌手名+别名表也没登记→维持原判,拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "",
			lyrics: chineseLyrics, want: true,
		},
		{
			name:        "罗马化标签+候选源报的歌手名同样是罗马化写法+别名表也没登记→救不了,拦",
			localArtist: "Zyx Qwerty Nonexistent", localTitle: "Some Song", candidateArtist: "Some Artist",
			lyrics: chineseLyrics, want: true,
		},
		{
			name:        "本地标签本身含汉字→本来就不适用这条判断,不拦",
			localArtist: "方大同", localTitle: "南音", candidateArtist: "",
			lyrics: chineseLyrics, want: false,
		},
		{
			name:        "本地标签非中文+候选正文也非中文→本来就没有语言分歧,不拦",
			localArtist: "Ed Sheeran", localTitle: "Shape of You", candidateArtist: "Ed Sheeran",
			lyrics: englishLyrics, want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := isProbablyWrongLanguageLyrics(c.localArtist, c.localTitle, c.candidateArtist, c.lyrics)
			if got != c.want {
				t.Errorf("isProbablyWrongLanguageLyrics(%q, %q, %q, ...) = %v, want %v",
					c.localArtist, c.localTitle, c.candidateArtist, got, c.want)
			}
		})
	}
}

func TestIsProbablyWrongLanguageLyricsUsesResolvedArtistCacheHint(t *testing.T) {
	chineseLyrics := "[00:35.34]不要把臉藏在月光背後\n[00:41.77]有誰在意我們的生活\n[00:45.67]坐在安靜角落"

	t.Run("artistAliasCache 命中→不拦", func(t *testing.T) {
		saved := artistAliasCache
		defer func() { artistAliasCache = saved }()
		artistAliasCache = map[string]string{"Na Ying": "那英"}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); got {
			t.Error("artistAliasCache 里已经查到中文名时不该拦")
		}
	})

	t.Run("mbPrimaryNameCache 命中→不拦", func(t *testing.T) {
		saved := mbPrimaryNameCache
		defer func() { mbPrimaryNameCache = saved }()
		mbPrimaryNameCache = map[string][]string{"Na Ying": {"那英"}}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); got {
			t.Error("mbPrimaryNameCache 里已经查到中文名时不该拦")
		}
	})

	t.Run("两份缓存都没查到→维持原判,拦", func(t *testing.T) {
		savedAlias, savedMB := artistAliasCache, mbPrimaryNameCache
		defer func() { artistAliasCache, mbPrimaryNameCache = savedAlias, savedMB }()
		artistAliasCache = map[string]string{}
		mbPrimaryNameCache = map[string][]string{}

		if got := isProbablyWrongLanguageLyrics("Na Ying", "Smiled Then Passed", "Na Ying", chineseLyrics); !got {
			t.Error("两份缓存都没有线索时应该维持原判(拦),不该凭空放行")
		}
	})

	t.Run("mbPrimaryNameCache 里全是非中文候选(查过但没有中文名)→不该误判成命中", func(t *testing.T) {
		saved := mbPrimaryNameCache
		defer func() { mbPrimaryNameCache = saved }()
		mbPrimaryNameCache = map[string][]string{"Some Artist": {"Some Other Latin Name"}}

		if got := isProbablyWrongLanguageLyrics("Some Artist", "Some Song", "Some Artist", chineseLyrics); !got {
			t.Error("缓存里的候选全是非中文时不该触发豁免")
		}
	})
}

func TestAlbumTokensLatinCJKBoundary(t *testing.T) {
	got := albumTokens("The One演唱会")
	if !got["one"] || !got["演唱会"] {
		t.Errorf("albumTokens(\"The One演唱会\") = %v,应拆出 one + 演唱会", got)
	}
	if got["one演唱会"] {
		t.Errorf("albumTokens(\"The One演唱会\") 不该再有粘连词元 one演唱会:%v", got)
	}

	got = albumTokens("2011Live")
	if !got["2011"] || !got["live"] {
		t.Errorf("albumTokens(\"2011Live\") = %v,应拆出 2011 + live", got)
	}

	got = albumTokens("周杰伦地表最强世界巡回演唱会")
	if len(got) != 1 || !got["周杰伦地表最强世界巡回演唱会"] {
		t.Errorf("纯 CJK 串仍应是单一词元,got %v", got)
	}
}

func TestAlbumScoreCrossScriptGlue(t *testing.T) {
	if sc := albumScore("The One演唱会", "The One 周杰伦演唱会"); sc < 1 {
		t.Errorf("QQ 拼法与本地拼法应有词元亲和,got %d", sc)
	}

	if sc := albumScore("八度空间", "The One 周杰伦演唱会"); sc != 0 {
		t.Errorf("八度空间 vs The One 应为 0,got %d", sc)
	}
}

func TestVersionTagsMismatchAlbumCJKLiveMarker(t *testing.T) {
	cases := []struct {
		name                                         string
		localTitle, localAlbum, candTitle, candAlbum string
		want                                         bool
	}{

		{"QQ 现场专辑曲目不再吃 -600", "龙拳 (Live)", "The One 周杰伦演唱会", "龙拳", "The One演唱会", false},

		{"录音室候选仍 mismatch", "龙拳 (Live)", "The One 周杰伦演唱会", "龙拳", "八度空间", true},

		{"本地现场专辑 vs 录音室候选", "龙拳", "The One 周杰伦演唱会", "龙拳", "八度空间", true},

		{"拉丁 live 词元不触发", "Live and Let Die", "Live and Let Die", "Live and Let Die", "Shaved Fish", false},

		{"双方专辑均带演唱会字样", "晴天", "XX演唱会", "晴天", "YY音乐会", false},
	}
	for _, c := range cases {
		if got := versionTagsMismatch(c.localTitle, c.localAlbum, c.candTitle, c.candAlbum); got != c.want {
			t.Errorf("%s:versionTagsMismatch(%q,%q,%q,%q) = %v,want %v",
				c.name, c.localTitle, c.localAlbum, c.candTitle, c.candAlbum, got, c.want)
		}
	}
}
