package main

import "testing"

func TestIsNeteasePureMusicLyric(t *testing.T) {
	cases := []struct {
		name string
		lrc  string
		want bool
	}{
		{
			name: "真实形态:作曲署名 + 占位(id=30431011 Demacia Rising)",
			lrc:  "[00:00.00] 作曲 : Michael Barry\n[00:05.00]纯音乐，请欣赏\n",
			want: true,
		},
		{
			name: "多位作曲 + 占位(id=30431020 Freljord)",
			lrc:  "[00:00.00] 作曲 : Sebastien Najand/Alexander Temple\n[00:05.00]纯音乐，请欣赏\n",
			want: true,
		},
		{
			name: "半角逗号那种写法",
			lrc:  "[00:00.00]纯音乐,请欣赏\n",
			want: true,
		},
		{
			name: "整份职员表但没有占位:不下「纯音乐」这个结论(交给判废逻辑处理)",
			lrc:  "[00:00.00] 作曲 : A\n[00:01.00] 作词 : B\n[00:02.00] 编曲 : C\n",
			want: false,
		},
		{
			name: "真歌词里唱到「纯音乐」:不算(有真正的歌词行)",
			lrc:  "[00:01.00]我在听纯音乐\n[00:05.00]夜色很安静\n[00:09.00]风吹过窗\n",
			want: false,
		},
		{
			name: "占位 + 一句真歌词:不算(自相矛盾时宁可不下结论)",
			lrc:  "[00:00.00]纯音乐，请欣赏\n[00:10.00]这里有一句真的歌词在唱\n",
			want: false,
		},
		{name: "空串", lrc: "", want: false},
		{name: "只有空白", lrc: "\n  \n", want: false},
	}
	for _, c := range cases {
		if got := isInstrumentalPlaceholderLyric(c.lrc); got != c.want {
			t.Errorf("%s: isInstrumentalPlaceholderLyric = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestMergeKeepsNeteaseInstrumentalMarkerBySource(t *testing.T) {
	marker := scoredLyricCandidateResult{Source: "netease", Score: -1, Instrumental: true}
	real := scoredLyricCandidateResult{
		Source: "kugou", Score: 100,
		Lyrics: "[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n",
	}

	out := mergeLyricCandidateRounds("A", "T", "AL", 0, []scoredLyricCandidateResult{marker, real}, nil)
	kept := false
	for _, r := range out {
		if r.Instrumental && r.Source == "netease" {
			kept = true
		}
	}
	if !kept {
		t.Error("网易云的纯音乐标记该留下(它自己没有真候选)")
	}

	neReal := real
	neReal.Source = "netease"
	out2 := mergeLyricCandidateRounds("A", "T", "AL", 0, []scoredLyricCandidateResult{marker, neReal}, nil)
	for _, r := range out2 {
		if r.Instrumental {
			t.Error("网易云已经给出真歌词候选,纯音乐标记不该保留")
		}
	}
}

func TestQQInstrumentalPlaceholderSurvivesTimedLRCFilter(t *testing.T) {

	const qqPlaceholder = "[00:00:00]此歌曲为没有填词的纯音乐，请您欣赏"

	if isTimedLRC(qqPlaceholder) {
		t.Errorf("前提变了:这行占位居然过了 isTimedLRC,那这个 bug 的成因描述要重写")
	}

	if !isInstrumentalPlaceholderLyric(qqPlaceholder) {
		t.Errorf("isInstrumentalPlaceholderLyric 必须认出 QQ 的纯音乐占位:%q", qqPlaceholder)
	}

	const neteaseCreditOnly = "[00:00.00-1] 作曲 : 蛋堡"
	if isInstrumentalPlaceholderLyric(neteaseCreditOnly) {
		t.Errorf("只有署名行不等于纯音乐,不该判 true:%q", neteaseCreditOnly)
	}

	real := "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	if isInstrumentalPlaceholderLyric(real) {
		t.Errorf("真歌词不该被判成纯音乐占位")
	}
}
