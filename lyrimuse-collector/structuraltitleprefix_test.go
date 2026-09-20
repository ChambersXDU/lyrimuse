package main

import (
	"reflect"
	"testing"
)

const medleyLocal = "Medley: Greatdayndamornin' / Booty"

func TestStripStructuralTitlePrefix(t *testing.T) {
	cases := []struct{ in, want string }{
		{medleyLocal, "Greatdayndamornin' / Booty"},
		{"Interlude: Something", "Something"},
		{"medley: lower case label", "lower case label"},
		{"Medley:NoSpace", "NoSpace"},

		{"Foo: Bar", "Foo: Bar"},
		{"Medleys: X", "Medleys: X"},
		{"Untitled (How Does It Feel)", "Untitled (How Does It Feel)"},
		{"No colon here", "No colon here"},
		{": leading colon", ": leading colon"},
		{"", ""},
	}
	for _, c := range cases {
		if got := stripStructuralTitlePrefix(c.in); got != c.want {
			t.Errorf("stripStructuralTitlePrefix(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSearchTitleVariantsStructuralPrefix(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{

		{medleyLocal, []string{"Greatdayndamornin' / Booty", medleyLocal}},

		{"Automatic (Remastered 2014)", []string{"Automatic", "Automatic (Remastered 2014)"}},

		{"Billie Jean (Single Version)", []string{"Billie Jean (Single Version)", "Billie Jean"}},

		{"Voodoo", []string{"Voodoo"}},
		{"Foo: Bar", []string{"Foo: Bar"}},
	}
	for _, c := range cases {
		if got := searchTitleVariants(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("searchTitleVariants(%q) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

func TestLyricTitleAcceptedStructuralPrefix(t *testing.T) {
	cases := []struct {
		candidate, local string
		want             bool
		why              string
	}{

		{"Greatdayndamornin'/Booty", medleyLocal, true, "源曲库里的裸曲名"},
		{"Greatdayndamornin' / Booty", medleyLocal, true, "斜杠两边带空格的写法"},
		{medleyLocal, "Greatdayndamornin'/Booty", true, "反向(前缀在候选那一侧)"},

		{"Real Love", "Real Love Baby", false, "子串,但两边都没有结构性前缀可砍"},
		{"Booty", medleyLocal, false, "串烧里的半首歌不算这首歌"},
		{"Greatdayndamornin'", medleyLocal, false, "同上,另外半首"},
		{"Bar", "Foo: Bar", false, "Foo 不在白名单,砍不掉"},

		{"Automatic", "Automatic (Remastered 2014)", true, "各自去括号后相等"},
		{"Voodoo", "Voodoo", true, "完全相等"},
		{"Something Else", "Voodoo", false, "毫无关系"},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("lyricTitleAccepted(%q, %q) = %v, want %v —— %s",
				c.candidate, c.local, got, c.want, c.why)
		}
	}
}
