package main

import "testing"

func TestTitleVersionTagsCantoneseMandarin(t *testing.T) {
	cases := []struct {
		title string
		want  []string
	}{
		{"K歌之王 (粵語)", []string{"粤语"}},
		{"K歌之王 (國語)", []string{"国语"}},

		{"K歌之王 [粤语]", []string{"粤语"}},
		{"K歌之王 [国语]", []string{"国语"}},

		{"Beyond - Cantonese Version", []string{"粤语"}},
		{"Beyond - Mandarin Version", []string{"国语"}},
		{"K歌之王 (國)", []string{"国语"}},
		{"K歌之王 (粵)", []string{"粤语"}},
		{"Mau U So(国)", []string{"国语"}},

		{"Song (国际版)", nil},
		{"Song (中国之星现场)", []string{"live"}},

		{"国语老歌精选", nil},
		{"粤语金曲", nil},
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

func TestVersionTagsMismatchCantoneseMandarin(t *testing.T) {
	cases := []struct {
		label      string
		local      string
		candidate  string
		wantMismat bool
	}{
		{"国语 vs 粤语必须判不匹配", "K歌之王 (國語)", "K歌之王 (粵語)", true},
		{"粤语 vs 国语反向同理", "K歌之王 (粵語)", "K歌之王 (國語)", true},
		{"两边都是粤语", "K歌之王 (粵語)", "K歌之王 [粤语]", false},
		{"两边都干净不该误伤", "K歌之王", "K歌之王", false},
		{"英文标签同理", "Song (Cantonese Version)", "Song (Mandarin Version)", true},
	}
	for _, c := range cases {
		got := versionTagsMismatch(c.local, "", c.candidate, "")
		if got != c.wantMismat {
			t.Errorf("%s: versionTagsMismatch(%q, %q) = %v, want %v", c.label, c.local, c.candidate, got, c.wantMismat)
		}
	}
}

func TestQQCanonicalLanguage(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{0, songLanguageMandarin},
		{1, songLanguageCantonese},
		{5, ""},
		{-1, ""},
		{99, ""},
	}
	for _, c := range cases {
		if got := qqCanonicalLanguage(c.in); got != c.want {
			t.Errorf("qqCanonicalLanguage(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestKugouCanonicalLanguage(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"国语", songLanguageMandarin},
		{"粤语", songLanguageCantonese},
		{"英语", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := kugouCanonicalLanguage(c.in); got != c.want {
			t.Errorf("kugouCanonicalLanguage(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
