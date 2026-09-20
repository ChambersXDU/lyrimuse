package main

import "testing"

func TestPlainTextFallbackFromScored(t *testing.T) {
	cases := []struct {
		name       string
		in         []scoredLyricCandidateResult
		wantLyrics string
		wantSource string
	}{
		{
			name: "有一条 PlainTextOnly 候选",
			in: []scoredLyricCandidateResult{
				{Source: "lrclib", Score: -1, PlainTextOnly: true, Lyrics: "只是一介草寇\n\n任魔鬼随意收割"},
			},
			wantLyrics: "只是一介草寇\n\n任魔鬼随意收割", wantSource: "lrclib",
		},
		{
			name: "普通被判废的候选(不是 PlainTextOnly)不算数",
			in: []scoredLyricCandidateResult{
				{Source: "netease", Score: -1, Lyrics: "作词 : 某某"},
			},
			wantLyrics: "", wantSource: "",
		},
		{
			name: "PlainTextOnly 但正文是空串:不算数——空字符串谈不上有内容",
			in: []scoredLyricCandidateResult{
				{Source: "lrclib", Score: -1, PlainTextOnly: true, Lyrics: ""},
			},
			wantLyrics: "", wantSource: "",
		},
		{
			name: "多条候选混杂,只取 PlainTextOnly 那条,不管它排在第几个",
			in: []scoredLyricCandidateResult{
				{Source: "netease", Score: -1, Lyrics: "作词 : 某某"},
				{Source: "qq", Score: -1},
				{Source: "lrclib", Score: -1, PlainTextOnly: true, Lyrics: "纯文本正文"},
				{Source: "musixmatch", Score: -1},
			},
			wantLyrics: "纯文本正文", wantSource: "lrclib",
		},
		{
			name: "空列表:不算数",
			in:   nil, wantLyrics: "", wantSource: "",
		},
	}
	for _, c := range cases {
		lyrics, source := plainTextFallbackFromScored(c.in)
		if lyrics != c.wantLyrics || source != c.wantSource {
			t.Errorf("%s: plainTextFallbackFromScored(...) = (%q, %q), want (%q, %q)",
				c.name, lyrics, source, c.wantLyrics, c.wantSource)
		}
	}
}
