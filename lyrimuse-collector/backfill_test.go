package main

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

func TestParseScrobbleEntries_SingleIsObjectNotArray(t *testing.T) {

	one := json.RawMessage(`{"timestamp":"1700000000","ignoredMessage":{"code":"0","#text":""}}`)
	got := parseScrobbleEntries(one)
	if len(got) != 1 || got[0].Timestamp != "1700000000" {
		t.Fatalf("single object form not parsed: %+v", got)
	}

	many := json.RawMessage(`[{"timestamp":"1","ignoredMessage":{"code":"0","#text":""}},` +
		`{"timestamp":"2","ignoredMessage":{"code":"0","#text":""}}]`)
	if got := parseScrobbleEntries(many); len(got) != 2 {
		t.Fatalf("array form not parsed: %+v", got)
	}

	if got := parseScrobbleEntries(json.RawMessage(`"garbage"`)); len(got) != 0 {
		t.Fatalf("unparseable payload should yield nothing, got %+v", got)
	}
}

func TestPendingBackfill_ExcludesSubmittedAndQuarantined(t *testing.T) {
	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()
	fresh := now.Add(-1 * time.Hour).Unix()

	appendListen("A", "unsubmitted", "al", fresh, 200)
	appendListen("B", "already-submitted", "al", fresh+1, 200)
	appendListen("C", "quarantined", "al", fresh+2, 200)
	markBackfilled(fresh + 1)
	markQuarantined(fresh + 2)

	pending, tooOld := pendingBackfillListens(now)
	if tooOld != 0 {
		t.Errorf("tooOld should be 0, got %d", tooOld)
	}
	if len(pending) != 1 || pending[0].TI != "unsubmitted" {
		t.Fatalf("want only the unsubmitted listen, got %+v", pending)
	}

	for _, p := range pending {
		if p.TI == "quarantined" {
			t.Fatal("a quarantined listen must never be picked up again automatically")
		}
	}
}

func TestPendingBackfill_SkipsTooOldAndSortsAscending(t *testing.T) {
	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()

	appendListen("Old", "way too old", "", now.Add(-30*24*time.Hour).Unix(), 200)

	appendListen("C", "third", "", now.Add(-1*time.Hour).Unix(), 200)
	appendListen("A", "first", "", now.Add(-3*time.Hour).Unix(), 200)
	appendListen("B", "second", "", now.Add(-2*time.Hour).Unix(), 200)

	appendListen("Short", "tiny", "", now.Add(-30*time.Minute).Unix(), 5)

	pending, tooOld := pendingBackfillListens(now)
	if tooOld != 1 {
		t.Errorf("want 1 too-old listen, got %d", tooOld)
	}
	var order []string
	for _, p := range pending {
		order = append(order, p.TI)
	}
	if len(order) != 3 || order[0] != "first" || order[1] != "second" || order[2] != "third" {
		t.Fatalf("want first,second,third in ascending uts order, got %v", order)
	}
}

func TestScrobbleBatch_RejectsOversizedBatch(t *testing.T) {

	s := &lastfmScrobbler{apiKey: "k", secret: "s", sk: "sk"}
	items := make([]listenLogLine, backfillBatchSize+1)
	if _, err := s.scrobbleBatch(nil, items); err == nil {
		t.Fatal("oversized batch must be rejected before any request is sent")
	}
}

func TestDryRunReturnsListNewestFirst(t *testing.T) {

	dir := t.TempDir()
	saved := listenLogPath
	defer func() { listenLogPath = saved }()
	listenLogPath = filepath.Join(dir, "l.jsonl")

	now := time.Now()
	appendListen("A", "oldest", "al1", now.Add(-3*time.Hour).Unix(), 200)
	appendListen("B", "middle", "", now.Add(-2*time.Hour).Unix(), 200)
	appendListen("C", "newest", "al3", now.Add(-1*time.Hour).Unix(), 200)

	out := runBackfill(context.Background(), nil, true)
	if out.Eligible != 3 || len(out.Items) != 3 {
		t.Fatalf("want 3 eligible and 3 items, got %d/%d", out.Eligible, len(out.Items))
	}
	if out.Items[0].Title != "newest" || out.Items[2].Title != "oldest" {
		t.Fatalf("items must be newest-first, got %s…%s", out.Items[0].Title, out.Items[2].Title)
	}

	if out.Items[0].Artist != "C" || out.Items[0].Album != "al3" || out.Items[0].UTS == 0 {
		t.Fatalf("item missing display fields: %+v", out.Items[0])
	}

	if out.Accepted != 0 || out.Quarantined != 0 {
		t.Fatalf("dry run must not submit anything: %+v", out)
	}
}
