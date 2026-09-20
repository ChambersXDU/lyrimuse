package main

import "testing"

func TestLoosenEnrichKeyFoldsCreditSeparators(t *testing.T) {
	same := [][2]string{
		{
			"VALORANT/Grabbitz/bbno$|Ticking Away|Ticking Away",
			"VALORANT & Grabbitz & bbno$|Ticking Away|Ticking Away",
		},
		{
			"英雄联盟/Mako/The Word Alive/The Glitch Mob|RISE|RISE",
			"英雄联盟 & Mako & The Word Alive & The Glitch Mob|RISE|RISE",
		},
		{
			"陶喆、卢广仲|某首歌|某专辑",
			"陶喆/卢广仲|某首歌|某专辑",
		},
		{

			"丁世光|無名花香|背面是我",
			"丁世光|无名花香|背面是我",
		},
	}
	for _, pair := range same {
		if loosenEnrichKey(pair[0]) != loosenEnrichKey(pair[1]) {
			t.Errorf("应判为同一首:\n  %q -> %q\n  %q -> %q",
				pair[0], loosenEnrichKey(pair[0]), pair[1], loosenEnrichKey(pair[1]))
		}
	}

	diff := [][2]string{
		{"K/DA|POP/STARS|POP/STARS", "K/DA|MORE|MORE"},
		{"VALORANT/Grabbitz|Die For You|Die For You", "VALORANT/Grabbitz|Ticking Away|Ticking Away"},
		{"A/B|同名歌|专辑甲", "A/B|同名歌|专辑乙"},
	}
	for _, pair := range diff {
		if loosenEnrichKey(pair[0]) == loosenEnrichKey(pair[1]) {
			t.Errorf("不该判为同一首: %q vs %q(都折成 %q)",
				pair[0], pair[1], loosenEnrichKey(pair[0]))
		}
	}
}
