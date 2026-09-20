package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestEnrichEntryJSONPreservesUnknownKeys(t *testing.T) {
	in := `{"ts":1700000000,"lyrics":"[00:01.00]a","lyrics_source":"qq",` +
		`"some_future_field":"kept","future_obj":{"x":[1,2,3]},"future_num":42}`
	var e enrichEntry
	if err := json.Unmarshal([]byte(in), &e); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if e.TS != 1700000000 || e.Lyrics != "[00:01.00]a" || e.LyricsSource != "qq" {
		t.Fatalf("known fields mangled: %+v", e)
	}
	if got := len(e.Unknown); got != 3 {
		t.Fatalf("Unknown = %v, want 3 keys", e.Unknown)
	}
	out, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var round map[string]json.RawMessage
	if err := json.Unmarshal(out, &round); err != nil {
		t.Fatalf("re-unmarshal: %v", err)
	}
	for k, want := range map[string]string{
		"some_future_field": `"kept"`,
		"future_obj":        `{"x":[1,2,3]}`,
		"future_num":        `42`,
		"lyrics_source":     `"qq"`,
	} {
		if string(round[k]) != want {
			t.Errorf("round-trip %s = %s, want %s", k, round[k], want)
		}
	}

	var m map[string]enrichEntry
	if err := json.Unmarshal([]byte(`{"k":`+in+`}`), &m); err != nil {
		t.Fatalf("map unmarshal: %v", err)
	}
	if len(m["k"].Unknown) != 3 {
		t.Fatalf("map value lost Unknown: %+v", m["k"].Unknown)
	}
	mo, _ := json.Marshal(m)
	if !strings.Contains(string(mo), `"some_future_field":"kept"`) {
		t.Fatalf("map marshal dropped unknown key: %s", mo)
	}
}

func TestEnrichEntryJSONIdenticalWhenNoUnknownKeys(t *testing.T) {
	e := enrichEntry{TS: 1, Lyrics: "[00:00.00]x", LyricsSource: "netease", LyricsScore: 900,
		LyricsSourcesSeen: []string{"netease", "qq"}, Instrumental: false}
	got, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(enrichEntryPlain(e))
	if string(got) != string(want) {
		t.Fatalf("marshal differs from plain encoding:\n got %s\nwant %s", got, want)
	}
	var back enrichEntry
	if err := json.Unmarshal(got, &back); err != nil {
		t.Fatal(err)
	}
	if back.Unknown != nil {
		t.Fatalf("Unknown should stay nil on a fully-known payload, got %v", back.Unknown)
	}
	if !reflect.DeepEqual(back, e) {
		t.Fatalf("round trip changed the entry:\n got %+v\nwant %+v", back, e)
	}
}

func TestEnrichEntryJSONKnownKeyWins(t *testing.T) {
	e := enrichEntry{TS: 5, Lyrics: "real"}
	e.Unknown = map[string]json.RawMessage{"lyrics": json.RawMessage(`"stale"`), "extra": json.RawMessage(`true`)}
	out, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	_ = json.Unmarshal(out, &m)
	if string(m["lyrics"]) != `"real"` || string(m["extra"]) != `true` {
		t.Fatalf("got %s", out)
	}
}

func TestEnrichEntriesWithUnknownKeys(t *testing.T) {
	m := map[string]enrichEntry{
		"a": {TS: 1},
		"b": {TS: 2, Unknown: map[string]json.RawMessage{"x": json.RawMessage(`1`)}},
		"c": {TS: 3, Unknown: map[string]json.RawMessage{}},
	}
	if n := enrichEntriesWithUnknownKeys(m); n != 1 {
		t.Fatalf("got %d, want 1", n)
	}
}

func TestEnrichEntryEveryFieldHasJSONTag(t *testing.T) {
	typ := reflect.TypeOf(enrichEntry{})
	for i := 0; i < typ.NumField(); i++ {
		f := typ.Field(i)
		if f.Tag.Get("json") == "" {
			t.Errorf("enrichEntry.%s has no json tag", f.Name)
		}
	}
	known := enrichEntryKnownJSONKeys()
	for _, k := range []string{"ts", "lyrics", "plain_lyrics", "song_language", "manual_pick_sha"} {
		if !known[k] {
			t.Errorf("known keys missing %q", k)
		}
	}
	if known["-"] {
		t.Error(`"-" must not be treated as a key`)
	}
}
