package main

import (
	"os"
	"reflect"
	"testing"
	"time"
)

func TestLyricsFillSweepCandidates(t *testing.T) {
	now := time.Now().Unix()
	day := int64(24 * 3600)
	savedCache, savedInflight := enrichCache, enrichInflight
	t.Cleanup(func() { enrichCache, enrichInflight = savedCache, savedInflight })
	enrichCache = map[string]enrichEntry{
		"a|old empty|":        {TS: now - 2*day},
		"b|fresh empty|":      {TS: now - 60},
		"c|has lyrics|":       {TS: now - 2*day, Lyrics: "[00:01.00]x"},
		"d|manual|":           {TS: now - 2*day, ManualLyrics: true},
		"e|instrumental|":     {TS: now - 2*day, Instrumental: true},
		"f|plain only|":       {TS: now - 2*day, PlainLyrics: "text"},
		"g|inflight|":         {TS: now - 2*day},
		"h|old empty second|": {TS: now - 3*day},
	}
	enrichInflight = map[string]bool{"g|inflight|": true}

	got := lyricsFillSweepCandidates(lyricsFillRequest{})
	want := []string{"a|old empty|", "f|plain only|", "h|old empty second|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("auto: got %v, want %v", got, want)
	}

	got = lyricsFillSweepCandidates(lyricsFillRequest{manual: true, all: true})
	want = []string{"a|old empty|", "b|fresh empty|", "f|plain only|", "h|old empty second|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("manual all: got %v, want %v", got, want)
	}

	got = lyricsFillSweepCandidates(lyricsFillRequest{manual: true, keys: map[string]bool{"b|fresh empty|": true, "c|has lyrics|": true, "zz|missing|": true}})
	want = []string{"b|fresh empty|"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("manual keys: got %v, want %v", got, want)
	}
}

func TestLyricsFillSweepDailyCap(t *testing.T) {
	now := time.Now().Unix()
	savedCache, savedInflight := enrichCache, enrichInflight
	t.Cleanup(func() { enrichCache, enrichInflight = savedCache, savedInflight })
	enrichCache = map[string]enrichEntry{}
	enrichInflight = map[string]bool{}
	for i := 0; i < lyricsFillSweepDailyCap+7; i++ {
		enrichCache[string(rune('a'+i%26))+string(rune('a'+i/26))+"|t|"] = enrichEntry{TS: now - 3*24*3600}
	}
	if got := len(lyricsFillSweepCandidates(lyricsFillRequest{})); got != lyricsFillSweepDailyCap {
		t.Errorf("auto sweep should cap at %d, got %d", lyricsFillSweepDailyCap, got)
	}
	if got := len(lyricsFillSweepCandidates(lyricsFillRequest{manual: true, all: true})); got != lyricsFillSweepDailyCap+7 {
		t.Errorf("manual sweep must not cap, got %d", got)
	}
}

func TestParseLyricsFillRequest(t *testing.T) {
	cases := []struct {
		in   string
		want lyricsFillRequest
	}{
		{"all\n", lyricsFillRequest{manual: true, all: true}},
		{"cancel", lyricsFillRequest{manual: true, cancel: true}},
		{"  周杰伦|晴天|叶惠美 \n\nA|B|C\n", lyricsFillRequest{manual: true, keys: map[string]bool{"周杰伦|晴天|叶惠美": true, "A|B|C": true}}},
		{"\n \n", lyricsFillRequest{manual: true}},
	}
	for _, c := range cases {
		if got := parseLyricsFillRequest(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("parse(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
}

func TestReadLyricsFillRequest(t *testing.T) {
	tmpDir := t.TempDir()
	reqPath := tmpDir + "/lyrics-fill-request.txt"
	savedPath := lyricsFillRequestPath
	defer func() { lyricsFillRequestPath = savedPath }()
	lyricsFillRequestPath = reqPath

	if _, ok := readLyricsFillRequest(); ok {
		t.Fatal("readLyricsFillRequest succeeded when file does not exist")
	}

	if err := os.WriteFile(reqPath, []byte("all\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	req, ok := readLyricsFillRequest()
	if !ok || !req.all {
		t.Fatalf("expected req.all=true, got ok=%v, req=%+v", ok, req)
	}

	if _, err := os.Stat(reqPath); !os.IsNotExist(err) {
		t.Fatalf("expected request file to be removed, stat err: %v", err)
	}
}
