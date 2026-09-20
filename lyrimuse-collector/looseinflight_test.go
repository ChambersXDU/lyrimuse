package main

import "testing"

func TestLooseInflightKeyCatchesEquivalentInFlight(t *testing.T) {
	old := enrichInflight
	enrichInflight = map[string]bool{}
	t.Cleanup(func() { enrichInflight = old })

	enrichInflight["方大同|春風吹之吹吹風mix|愛愛愛"] = true

	if got, busy := looseInflightKey("方大同|春风吹之吹吹风mix|愛愛愛"); !busy {
		t.Errorf("简体写法没被在途的繁体条目挡住,会长出重复(got=%q)", got)
	}

	if _, busy := looseInflightKey("方大同|春風吹之吹吹風 mix|愛愛愛"); !busy {
		t.Error("空格变体没被挡住")
	}

	if _, busy := looseInflightKey("方大同|春風吹之吹吹風mix|愛愛愛"); !busy {
		t.Error("精确同名没被认成在途")
	}

	if _, busy := looseInflightKey("方大同|三人游|愛愛愛"); busy {
		t.Error("另一首歌被误判成在途,它的歌词将永远解析不出来")
	}

	if _, busy := looseInflightKey("方大同|春風吹之吹吹風mix (Live)|愛愛愛"); busy {
		t.Error("Live 版被误判成在途")
	}
}

func TestLooseInflightKeyEmptyQueue(t *testing.T) {
	old := enrichInflight
	enrichInflight = map[string]bool{}
	t.Cleanup(func() { enrichInflight = old })

	if _, busy := looseInflightKey("陶喆|Susan 说|太平盛世"); busy {
		t.Error("空队列不该报在途")
	}
}
