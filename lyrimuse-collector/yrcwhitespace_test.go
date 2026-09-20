package main

import "testing"

func TestYRCMergeWhitespaceTokensMusixmatchShape(t *testing.T) {
	in := "[1980,4087](1980,23,0)In(2003,165,0) (2168,24,0)the(2192,96,0) (2288,40,0)nick\n"
	want := "[1980,4087](1980,188,0)In (2168,120,0)the (2288,40,0)nick\n"
	got, changed := yrcMergeWhitespaceTokens(in)
	if !changed {
		t.Fatalf("应报告已修改")
	}
	if got != want {
		t.Fatalf("归并结果不对:\n got %q\nwant %q", got, want)
	}

	again, changed2 := yrcMergeWhitespaceTokens(got)
	if changed2 || again != got {
		t.Fatalf("应幂等: %q", again)
	}
}

func TestYRCMergeWhitespaceTokensNeteaseUntouched(t *testing.T) {
	in := "[ar:某人]\n[100,2000](100,300,0)word (500,300,0)gap留白 (1000,500,0)tail\n"
	got, changed := yrcMergeWhitespaceTokens(in)
	if changed || got != in {
		t.Fatalf("无空白词条的内容不该被改动: %q", got)
	}
}

func TestYRCMergeWhitespaceTokensLeadingSpace(t *testing.T) {
	in := "[0,1000](0,50,0) (50,200,0)hi\n"
	want := "[0,1000](50,200,0) hi\n"
	got, changed := yrcMergeWhitespaceTokens(in)
	if !changed || got != want {
		t.Fatalf("行首空白应并给下一个词:\n got %q\nwant %q", got, want)
	}
}

func TestRichsyncToYRCMergesWhitespaceEntries(t *testing.T) {
	lines := []musixmatchRichsyncLine{{
		Ts: 1.98, Te: 6.067,
		L: []musixmatchRichsyncWord{
			{C: "In", O: 0},
			{C: " ", O: 0.023},
			{C: "the", O: 0.188},
			{C: " ", O: 0.212},
			{C: "nick", O: 0.308},
		},
	}}
	got := richsyncToYRC(lines)
	want := "[1980,4087](1980,188,0)In (2168,120,0)the (2288,3779,0)nick\n"
	if got != want {
		t.Fatalf("richsyncToYRC 归并不对:\n got %q\nwant %q", got, want)
	}
}
