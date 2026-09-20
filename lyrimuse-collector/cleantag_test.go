package main

import "testing"

func TestCleanMediaTag_StripsInvisibleWhitespace(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"尾部 NBSP", "偷笑\u00a0", "偷笑"},
		{"尾部 NBSP(带感叹号)", "唉!\u00a0", "唉!"},
		{"中段 NBSP", "A\u00a0B", "A B"},
		{"全角空格", "A\u3000B", "A B"},
		{"窄不换行空格", "A\u202fB", "A B"},
		{"零宽字符直接删", "A\u200bB", "AB"},
		{"BOM 直接删", "\ufeffABC", "ABC"},
		{"连续空白折成一个", "A   B", "A B"},
		{"首尾空白去掉", "  ABC  ", "ABC"},
		{"空串原样返回", "", ""},
		{"大小写不动", "PRINCE", "PRINCE"},
		{"正常标题不受影响", "I Wanna Be Your Lover", "I Wanna Be Your Lover"},
		{"中文标题不受影响", "四人游", "四人游"},
	}
	for _, c := range cases {
		if got := cleanMediaTag(c.in); got != c.want {
			t.Errorf("%s: cleanMediaTag(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestCleanMediaTag_CollapsesTheRealDuplicateKeys(t *testing.T) {
	key := func(artist, title, album string) string {
		return cleanMediaTag(artist) + "|" + cleanMediaTag(title) + "|" + cleanMediaTag(album)
	}
	if a, b := key("方大同", "偷笑", "爱爱爱"), key("方大同", "偷笑\u00a0", "爱爱爱"); a != b {
		t.Fatalf("两条真实重复 key 洗完仍不相等:\n  %q\n  %q", a, b)
	}
}
