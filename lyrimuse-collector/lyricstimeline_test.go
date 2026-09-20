package main

import "testing"

const (

	rumourLRC = "[ti:Rumour Has It]\n" +
		"[ar:Adele]\n" +
		"\n" +
		"[00:27.41] She, she ain't real\n" +
		"[00:28.16] She ain't gon' be able to love you like I will\n" +
		"[00:48.43] Rumour has it (rumour)\n" +
		"[00:50.82] Rumour has it (rumour)"
	rumourYRC = "[18315,1857](18315,1212,0)She, (19527,177,0)she (19704,299,0)ain't (20003,169,0)real\n" +
		"[21184,1900](21184,48,0)She (21232,96,0)ain't (21328,100,0)gon' (21428,167,0)be (21595,233,0)able (21828,378,0)to (22206,288,0)love (22494,223,0)you (22717,311,0)like (23028,56,0)I (23084,0,0)will\n" +
		"[59722,1414](59722,187,0)Rumour (59909,34,0)has (59943,11,0)it (59954,1182,0)(rumour)\n" +
		"[61136,462](61136,262,0)Rumour (61398,67,0)has (61465,44,0)it (61509,89,0)(rumour)"
	rumourTr = "[00:27.41]她，她不是真的\n" +
		"[00:28.16]她不可能像我一样爱你\n" +
		"[00:48.43]有传言（谣言）"
)

func TestYRCLineHeadsKeepsLiteralParens(t *testing.T) {
	heads := yrcLineHeads(rumourYRC)
	if len(heads) != 4 {
		t.Fatalf("行数: got %d want 4", len(heads))
	}
	if heads[2].text != "Rumour has it (rumour)" {
		t.Errorf("字面左括号被截断: got %q want %q", heads[2].text, "Rumour has it (rumour)")
	}
	if heads[0].ms != 18315 || heads[3].ms != 61136 {
		t.Errorf("行首时间: got %d/%d want 18315/61136", heads[0].ms, heads[3].ms)
	}
}

func TestRehangLRCOnYRCRealCase(t *testing.T) {
	got, remap, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("应当重挂,实际放弃了")
	}
	want := "[ti:Rumour Has It]\n" +
		"[ar:Adele]\n" +
		"\n" +
		"[00:18.31]She, she ain't real\n" +
		"[00:21.18]She ain't gon' be able to love you like I will\n" +
		"[00:59.72]Rumour has it (rumour)\n" +
		"[01:01.13]Rumour has it (rumour)"
	if got != want {
		t.Errorf("重挂结果不符\ngot:\n%s\nwant:\n%s", got, want)
	}

	if n := len(splitLines(got)); n != len(splitLines(rumourLRC)) {
		t.Errorf("行数变了: got %d want %d", n, len(splitLines(rumourLRC)))
	}

	if remap[27410] != 18315 {
		t.Errorf("remap[27410]: got %d want 18315", remap[27410])
	}
}

func TestRehangLRCOnYRCIdempotent(t *testing.T) {
	once, _, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("第一遍应当重挂")
	}
	if _, _, ok2 := rehangLRCOnYRC(once, rumourYRC, 223.266, true); ok2 {
		t.Error("第二遍不该再改")
	}
}

func TestRehangLRCOnYRCRejects(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		yrc  string
	}{
		{

			name: "行数不等",
			lrc:  "[00:27.41] She, she ain't real\n[00:28.16] She ain't gon' be able to love you like I will\n[00:48.43] 制作人 : Someone",
			yrc:  rumourYRC,
		},
		{
			name: "逐行文本对不上",
			lrc:  "[00:27.41] 完全不同的一句\n[00:28.16] 另一句也不同\n[00:48.43] 第三句\n[00:50.82] 第四句",
			yrc:  rumourYRC,
		},
		{

			name: "一行多戳",
			lrc:  "[00:27.41][01:27.41] She, she ain't real\n[00:28.16] She ain't gon' be able to love you like I will\n[00:48.43] Rumour has it (rumour)\n[00:50.82] Rumour has it (rumour)",
			yrc:  rumourYRC,
		},
		{
			name: "逐字轴乱序",
			lrc:  rumourLRC,
			yrc: "[59722,1414](59722,187,0)She, (59909,34,0)she (59943,11,0)ain't (59954,1182,0)real\n" +
				"[21184,1900](21184,48,0)She (21232,96,0)ain't (21328,100,0)gon' (21428,167,0)be (21595,233,0)able (21828,378,0)to (22206,288,0)love (22494,223,0)you (22717,311,0)like (23028,56,0)I (23084,0,0)will\n" +
				"[18315,1857](18315,1212,0)Rumour (19527,177,0)has (19704,299,0)it (20003,169,0)(rumour)\n" +
				"[61136,462](61136,262,0)Rumour (61398,67,0)has (61465,44,0)it (61509,89,0)(rumour)",
		},
		{name: "没有逐字轴", lrc: rumourLRC, yrc: ""},
		{name: "没有正文", lrc: "", yrc: rumourYRC},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, _, ok := rehangLRCOnYRC(c.lrc, c.yrc, 223.266, true)
			if ok {
				t.Errorf("应当放弃重挂,实际改了:\n%s", got)
			}
			if got != c.lrc {
				t.Error("放弃时必须原样返回")
			}
		})
	}
}

func TestRehangLRCOnYRCDurationGuard(t *testing.T) {
	lrc := "[02:56.10]first line here\n[02:56.20]second line here"
	yrc := "[216600,500](216600,250,0)first (216850,250,0)line (217100,100,0)here\n" +
		"[216700,500](216700,250,0)second (216950,250,0)line (217200,100,0)here"
	const dur = 204.2
	if _, _, ok := rehangLRCOnYRC(lrc, yrc, dur, true); ok {
		t.Error("重挂会让歌词尾巴甩出曲目,安全闸应当拦下")
	}

	if _, _, ok := rehangLRCOnYRC(lrc, yrc, 0, true); ok {
		t.Error("曲长未知时带闸应当放弃")
	}

	if _, _, ok := rehangLRCOnYRC(lrc, yrc, 0, false); !ok {
		t.Error("不带闸时应当照改")
	}
}

func TestRemapLRCTimestamps(t *testing.T) {
	_, remap, ok := rehangLRCOnYRC(rumourLRC, rumourYRC, 223.266, true)
	if !ok {
		t.Fatal("前置重挂失败")
	}
	got, changed := remapLRCTimestamps(rumourTr, remap)
	if !changed {
		t.Fatal("译文应当被搬到新轴")
	}
	want := "[00:18.31]她，她不是真的\n" +
		"[00:21.18]她不可能像我一样爱你\n" +
		"[00:59.72]有传言（谣言）"
	if got != want {
		t.Errorf("译文重挂不符\ngot:\n%s\nwant:\n%s", got, want)
	}

	partial := "[00:27.41]她，她不是真的\n[09:99.99]查不到的一行"
	got2, changed2 := remapLRCTimestamps(partial, remap)
	if !changed2 {
		t.Fatal("有一行能搬就该搬")
	}
	if got2 != "[00:18.31]她，她不是真的\n[09:99.99]查不到的一行" {
		t.Errorf("查不到的行应原样保留: got %q", got2)
	}
	if _, changed3 := remapLRCTimestamps("", remap); changed3 {
		t.Error("空译文不该报 changed")
	}
}

func TestRehangCandidateTimelines(t *testing.T) {
	cands := []lyricCandidate{
		{source: "musixmatch", lyrics: rumourLRC, wordTimingYRC: rumourYRC},
		{source: "lrclib", lyrics: rumourLRC},
	}
	rehangCandidateTimelines(cands, 223.266)
	if cands[0].lyrics == rumourLRC {
		t.Error("带逐字轴的候选应当被重挂")
	}
	if len(cands[0].timelineRemap) == 0 {
		t.Error("重挂过的候选应当留下映射供译文复用")
	}
	if cands[1].lyrics != rumourLRC || cands[1].timelineRemap != nil {
		t.Error("没有逐字轴的候选不该被动")
	}
}

const (
	taikongLRC = "[00:32.30]大预言话:地球是大限将至\n" +
		"[00:36.10]到今天还是未有事\n" +
		"[00:40.29]未是时候就无谓乱下赌注\n" +
		"[00:44.10]去侦测太空怎样住\n" +
		"[00:48.10]水星 发梦有附送\n" +
		"[00:50.80]火星 怪物无尽\n" +
		"[00:52.10]可否 继续留在被窝之中(其实)\n" +
		"[00:55.61]金星 引力那样重\n" +
		"[00:58.90]土星 行为迟钝\n" +
		"[01:00.38]穿梭机中 几秒后已经想看钟"
	taikongYRC = "[74349,3290](74349,242,0)大(74591,170,0)预(74761,164,0)言(74925,196,0)话(75121,168,0):(75289,170,0)地(75459,160,0)球(75619,190,0)是(75809,208,0)大(76017,264,0)限(76281,232,0)将(76513,1126,0)至\n" +
		"[77639,3999](77639,200,0)到(77839,198,0)今(78037,204,0)天(78241,216,0)还(78457,264,0)是(78721,230,0)未(78951,214,0)有(79165,2473,0)事\n" +
		"[81638,3236](81638,196,0)未(81834,180,0)是(82014,182,0)时(82196,258,0)候(82454,180,0)就(82634,216,0)无(82850,218,0)谓(83068,210,0)乱(83278,216,0)下(83494,216,0)赌(83710,1164,0)注\n" +
		"[84874,3868](84874,248,0)去(85122,212,0)侦(85334,200,0)测(85534,196,0)太(85730,256,0)空(85986,246,0)怎(86232,218,0)样(86450,2292,0)住\n" +
		"[88742,1850](88742,220,0)水(88962,408,0)星 (89370,228,0)引(89598,232,0)力(89830,224,0)那(90054,232,0)样(90286,306,0)重\n" +
		"[90592,1799](90592,226,0)火(90818,248,0)星 (91066,240,0)怪(91306,204,0)物(91510,248,0)无(91758,633,0)尽\n" +
		"[92391,3480](92391,208,0)可(92599,224,0)否 (92823,272,0)继(93095,720,0)续(93815,236,0)留(94051,216,0)在(94267,204,0)被(94471,200,0)窝(94671,200,0)之(94871,232,0)中(95103,264,0)（(95367,216,0)其(95583,288,0)实\n" +
		"[96159,1656](96159,198,0)金(96357,234,0)星 (96591,228,0)引(96819,232,0)力(97051,252,0)那(97303,208,0)样(97511,304,0)重\n" +
		"[97815,1888](97815,224,0)土(98039,252,0)星 (98291,252,0)行(98543,244,0)为(98787,248,0)迟(99035,668,0)钝\n" +
		"[99703,5021](99703,206,0)穿(99909,202,0)梭(100111,220,0)机(100331,374,0)中 (100705,212,0)几(100917,214,0)秒(101131,282,0)后(101413,206,0)已(101619,200,0)经(101819,232,0)想(102051,212,0)看(102263,2461,0)钟"
)

func TestWordTimingContradictsLRC(t *testing.T) {

	if !wordTimingContradictsLRC(taikongLRC, taikongYRC) {
		t.Error("《2001太空漫游 (Live)》形态(中位偏差 40s+)应判为矛盾")
	}

	consistent := "[01:14.35]大预言话:地球是大限将至\n" +
		"[01:17.64]到今天还是未有事\n" +
		"[01:21.64]未是时候就无谓乱下赌注\n" +
		"[01:24.87]去侦测太空怎样住\n" +
		"[01:28.74]水星 发梦有附送\n" +
		"[01:30.59]火星 怪物无尽\n" +
		"[01:32.39]可否 继续留在被窝之中(其实)\n" +
		"[01:36.16]金星 引力那样重\n" +
		"[01:37.82]土星 行为迟钝\n" +
		"[01:39.70]穿梭机中 几秒后已经想看钟"
	if wordTimingContradictsLRC(consistent, taikongYRC) {
		t.Error("时间戳基本一致的双轴不该判矛盾")
	}

	if wordTimingContradictsLRC(rumourLRC, rumourYRC) {
		t.Error("配对行不足下限时不该判矛盾(拿不准就不动)")
	}
	if wordTimingContradictsLRC("", taikongYRC) || wordTimingContradictsLRC(taikongLRC, "") {
		t.Error("缺任一侧时不该判矛盾")
	}
}

func TestRehangCandidateTimelinesDropsContradictoryYRC(t *testing.T) {
	cands := []lyricCandidate{
		{source: "netease", lyrics: taikongLRC, wordTimingYRC: taikongYRC, hasWordTiming: true},
		{source: "musixmatch", lyrics: rumourLRC, wordTimingYRC: rumourYRC, hasWordTiming: true},
	}
	rehangCandidateTimelines(cands, 221.599)
	if cands[0].wordTimingYRC != "" || cands[0].hasWordTiming {
		t.Error("自相矛盾的逐字轴应被弃用")
	}

	if cands[1].wordTimingYRC == "" || !cands[1].hasWordTiming {
		t.Error("可重挂的双轴不该被弃用")
	}
	if cands[1].lyrics == rumourLRC {
		t.Error("可重挂的候选应当被重挂")
	}
}

func splitLines(s string) []string {
	n := 1
	for _, r := range s {
		if r == '\n' {
			n++
		}
	}
	out := make([]string, 0, n)
	start := 0
	for i, r := range s {
		if r == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
