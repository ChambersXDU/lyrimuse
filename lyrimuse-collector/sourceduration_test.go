package main

import (
	"fmt"
	"strings"
	"testing"
)

const (
	moscowLocalTitle = "Stranger in Moscow (Tee's In-House Club Mix)"
	moscowLocalAlbum = "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix"
	moscowLocalDur   = 414.32
)

func TestVersionTagsCoverClubMixFamily(t *testing.T) {
	tagged := []string{
		"Stranger in Moscow (Tee's In-House Club Mix)",
		"Stranger in Moscow (Tee's Radio Mix)",
		"Some Song (Deep House Mix)",
		"Some Song (Danger Dub Mix)",
		"Some Song (Dance Mix)",
		"Some Song (Vocal Mix)",
		"Some Song (Club Edit)",
	}
	for _, ti := range tagged {
		if len(titleVersionTags(ti)) == 0 {
			t.Errorf("titleVersionTags(%q) 应抽出版本限定词", ti)
		}
	}

	if got := titleVersionTags("Earth Song (Hani's club experience)"); len(got) != 0 {
		t.Errorf("titleVersionTags(\"Earth Song (Hani's club experience)\") = %v, 必须为空 —— "+
			"裸「club」进词表会把这首歌唯一正确的候选打成版本不符", got)
	}

	if got := titleVersionTags("BLOOD ON THE DANCE FLOOR/ HIStory In The Mix"); len(got) != 0 {
		t.Errorf("专辑名 \"…HIStory In The Mix\" 不该抽出限定词,得到 %v", got)
	}
}

func TestSearchTitleVariantsPutsClubMixTitleFirst(t *testing.T) {
	got := searchTitleVariants(moscowLocalTitle)
	if len(got) == 0 || got[0] != moscowLocalTitle {
		t.Fatalf("searchTitleVariants(%q) = %#v,第一条必须是原样标题", moscowLocalTitle, got)
	}
	if len(got) < 2 || got[1] != "Stranger in Moscow" {
		t.Errorf("裸标题应保留作兜底,得到 %#v", got)
	}
}

func TestVersionTagsMismatchFlagsStandardVersion(t *testing.T) {
	if !versionTagsMismatch(moscowLocalTitle, moscowLocalAlbum,
		"Stranger In Moscow", "HIStory - PAST, PRESENT AND FUTURE - BOOK I (Explicit)") {
		t.Errorf("本地是俱乐部混音、候选是正常专辑版,应判版本不符")
	}

	if versionTagsMismatch(moscowLocalTitle, moscowLocalAlbum, moscowLocalTitle, moscowLocalAlbum) {
		t.Errorf("同一版本不该判不符")
	}
}

func TestScoreSourceDurationMismatch(t *testing.T) {
	hasTerm := func(terms []scoreTerm) (int, bool) {
		for _, tm := range terms {
			if tm.Kind == scoreTermSourceDurationOff {
				return tm.Points, true
			}
		}
		return 0, false
	}
	lrc := lrcEndingAt(400, 20)
	cases := []struct {
		name    string
		srcDur  float64
		wantHit bool
	}{
		{"自报 344s vs 本地 414.32s(偏 17%)→ 扣", 344, true},
		{"自报 413s vs 本地 414.32s(偏 0.3%)→ 不扣", 413, false},
		{"自报 370s(偏 10.7%,在 12% 内)→ 不扣", 370, false},
		{"自报 360s(偏 13.1%)→ 扣", 360, true},
		{"源没自报(0)→ 不扣(没有证据不等于反面证据)", 0, false},
		{"自报比本地长很多(偏 20%)→ 扣", 517.9, true},
	}
	for _, c := range cases {
		cand := lyricCandidate{source: "kugou", lyrics: lrc, sourceReportedDurationSecs: c.srcDur}
		_, terms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
			moscowLocalDur, cand, false, 0)
		pts, hit := hasTerm(terms)
		if hit != c.wantHit {
			t.Errorf("%s: 扣分项出现=%v,want %v", c.name, hit, c.wantHit)
		}
		if hit && pts != -sourceDurationMismatchPenalty {
			t.Errorf("%s: 扣了 %d,want %d", c.name, pts, -sourceDurationMismatchPenalty)
		}
	}
}

func TestMoscowClubMixOutranksStandardVersion(t *testing.T) {
	standard := lyricCandidate{
		source: "qq", lyrics: lrcEndingAt(335, 70), hasWordTiming: true, wordTimingYRC: "x",
		sourceReportedDurationSecs: 344,
		title:                      "Stranger In Moscow",
		album:                      "HIStory - PAST, PRESENT AND FUTURE - BOOK I (Explicit)",
	}
	clubMix := lyricCandidate{
		source: "kugou", lyrics: lrcEndingAt(305, 65), hasWordTiming: true, wordTimingYRC: "x",
		sourceReportedDurationSecs: 413,
		title:                      moscowLocalTitle,
		album:                      moscowLocalAlbum,
	}
	ss, sterms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
		moscowLocalDur, standard, false, 2)
	cs, cterms := scoreLyricCandidateDetailed("Michael Jackson", moscowLocalTitle, moscowLocalAlbum,
		moscowLocalDur, clubMix, false, 0)
	dump := func(n string, s int, ts []scoreTerm) string {
		var b strings.Builder
		fmt.Fprintf(&b, "%s=%d [", n, s)
		for _, tm := range ts {
			fmt.Fprintf(&b, "%s%+d ", tm.Kind, tm.Points)
		}
		b.WriteString("]")
		return b.String()
	}
	if cs <= ss {
		t.Errorf("混音版必须胜出\n  %s\n  %s", dump("clubMix", cs, cterms), dump("standard", ss, sterms))
	}
	t.Logf("%s\n  %s", dump("clubMix ", cs, cterms), dump("standard", ss, sterms))
}
