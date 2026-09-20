package main

import "testing"

func TestExtractQRCLyricContentKeepsLiteralQuotes(t *testing.T) {

	xml := `<?xml version="1.0" encoding="utf-8"?>` + "\n" +
		`<QrcInfos><QrcHeadInfo SaveTime="1" Version="1"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="[48794,2069]And (48962,124)you say ` +
		`&quot;A&quot; "What have I got to lose" and more(1,2)` + "\n" +
		`[51000,900]last line(51000,900)` + "\n" +
		`"/>` + "\n</LyricInfo>\n</QrcInfos>"

	got := extractQRCLyricContent(xml)
	if got == "" {
		t.Fatal("截出空串")
	}

	for _, want := range []string{"What have I got to lose", "and more", "last line"} {
		if !contains(got, want) {
			t.Errorf("正文在字面引号处被截断了,丢了 %q\n实际截出: %q", want, got)
		}
	}

	if !contains(got, `"A"`) {
		t.Errorf("&quot; 没有被反转义: %q", got)
	}

	if contains(got, `"/>`) {
		t.Errorf("正文里混进了结构标记 \"/>: %q", got)
	}
}

func TestExtractQRCLyricContentToleratesSpaceBeforeSelfClose(t *testing.T) {
	xml := `<Lyric_1 LyricContent="[1,2]hi(1,2)" />`
	if got := extractQRCLyricContent(xml); got != "[1,2]hi(1,2)" {
		t.Errorf("got %q", got)
	}
}

func TestExtractQRCLyricContentMissing(t *testing.T) {
	if got := extractQRCLyricContent(`<QrcInfos><LyricInfo LyricCount="0"/></QrcInfos>`); got != "" {
		t.Errorf("没有 LyricContent 时应返回空串,得到 %q", got)
	}
	if got := extractQRCLyricContent(""); got != "" {
		t.Errorf("空输入应返回空串,得到 %q", got)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
