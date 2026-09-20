package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func setupEnrichPersistenceTest(t *testing.T) string {
	t.Helper()
	cache, path, dirty := enrichCache, enrichPath, enrichDirty
	baseline, baselinePath, ready := enrichBaseline, enrichBaselinePath, enrichBaselineReady
	generations, dir := enrichExternalGeneration, lyricsDir
	t.Cleanup(func() {
		enrichCache, enrichPath, enrichDirty = cache, path, dirty
		enrichBaseline, enrichBaselinePath, enrichBaselineReady = baseline, baselinePath, ready
		enrichExternalGeneration, lyricsDir = generations, dir
	})
	enrichCache = map[string]enrichEntry{}
	enrichBaseline = nil
	enrichBaselineReady = false
	enrichExternalGeneration = map[string]uint64{}
	enrichPath = filepath.Join(t.TempDir(), "cache.json")
	lyricsDir = filepath.Join(filepath.Dir(enrichPath), "lyrics")
	return enrichPath
}

func writeEnrichDiskTest(t *testing.T, path string, entries map[string]enrichEntry) {
	t.Helper()
	data, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestEnrichPersistenceKeepsExternalChangesAndLocalFields(t *testing.T) {
	path := setupEnrichPersistenceTest(t)
	const edited = "Artist|Edited|Album"
	const deleted = "Artist|Deleted|Album"
	writeEnrichDiskTest(t, path, map[string]enrichEntry{
		edited: {Lyrics: "old", CoverURL: "old cover"}, deleted: {Lyrics: "remove me"},
	})
	loadEnrichCache(path)
	enrichCache[edited] = enrichEntry{Lyrics: "stale candidate", CoverURL: "fresh cover"}
	enrichCache[deleted] = enrichEntry{Lyrics: "stale candidate too"}
	enrichCache["local"] = enrichEntry{Lyrics: "local addition"}
	enrichDirty = true
	writeEnrichDiskTest(t, path, map[string]enrichEntry{
		edited:     {Lyrics: "manual", CoverURL: "old cover", ManualLyrics: true, Unknown: map[string]json.RawMessage{"future": json.RawMessage(`true`)}},
		"external": {Lyrics: "external addition"},
	})
	saveEnrichCache()
	disk, err := readEnrichCacheDisk(path)
	if err != nil {
		t.Fatal(err)
	}
	if disk[edited].Lyrics != "manual" || disk[edited].CoverURL != "fresh cover" || !disk[edited].ManualLyrics {
		t.Fatalf("lost merged fields: %+v", disk[edited])
	}
	if string(disk[edited].Unknown["future"]) != "true" {
		t.Fatal("lost unknown field")
	}
	if _, ok := disk[deleted]; ok {
		t.Fatal("resurrected externally deleted entry")
	}
	if disk["local"].Lyrics == "" || disk["external"].Lyrics == "" {
		t.Fatalf("lost additions: %+v", disk)
	}
	if enrichDirty {
		t.Fatal("successful commit stayed dirty")
	}
	commitEnrichEntry(edited, enrichEntry{Lyrics: "late result"}, 0)
	commitEnrichEntry(deleted, enrichEntry{Lyrics: "late deleted result"}, 0)
	if enrichCache[edited].Lyrics != "manual" {
		t.Fatal("late search undid manual edit")
	}
	if _, ok := enrichCache[deleted]; ok {
		t.Fatal("late search resurrected deleted entry")
	}
	e := enrichCache[edited]
	e.AccentColor = "fresh accent"
	enrichCache[edited] = e
	enrichDirty = true
	saveEnrichCache()
	disk, err = readEnrichCacheDisk(path)
	if err != nil || disk[edited].AccentColor != "fresh accent" {
		t.Fatalf("subsequent local update lost: %v", err)
	}
}

func TestEnrichPersistenceFailureKeepsDirtyAndBaseline(t *testing.T) {
	path := setupEnrichPersistenceTest(t)
	writeEnrichDiskTest(t, path, map[string]enrichEntry{"song": {Lyrics: "old"}})
	loadEnrichCache(path)
	enrichCache["song"] = enrichEntry{Lyrics: "new"}
	enrichDirty = true
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	saveEnrichCache()
	data, _ := os.ReadFile(path)
	if string(data) != "broken" || !enrichDirty || enrichBaseline["song"].Lyrics != "old" {
		t.Fatal("failed read changed disk, baseline, or dirty flag")
	}
	writeEnrichDiskTest(t, path, map[string]enrichEntry{"song": {Lyrics: "old"}})
	if err := os.Remove(path + ".lock"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path+".lock", 0700); err != nil {
		t.Fatal(err)
	}
	saveEnrichCache()
	if !enrichDirty || enrichBaseline["song"].Lyrics != "old" {
		t.Fatal("lock failure advanced baseline or cleared dirty")
	}
	if err := os.Remove(path + ".lock"); err != nil {
		t.Fatal(err)
	}
	saveEnrichCache()
	if enrichDirty {
		t.Fatal("retry did not succeed")
	}
}

func TestEnrichExportDoesNotRestoreExternalDeletion(t *testing.T) {
	path := setupEnrichPersistenceTest(t)
	const key = "Artist|Song|Album"
	writeEnrichDiskTest(t, path, map[string]enrichEntry{key: {Lyrics: "old"}})
	loadEnrichCache(path)
	exportLyricsFiles()
	lyric := filepath.Join(lyricsDir, sanitizeLyricsFilename(key)+".lrc")
	if _, err := os.Stat(lyric); err != nil {
		t.Fatal(err)
	}
	writeEnrichDiskTest(t, path, map[string]enrichEntry{})
	if err := os.Remove(lyric); err != nil {
		t.Fatal(err)
	}
	exportLyricsFiles()
	if _, err := os.Stat(lyric); !os.IsNotExist(err) {
		t.Fatalf("export resurrected file: %v", err)
	}
	commitEnrichEntry(key, enrichEntry{Lyrics: "late result"}, 0)
	if _, ok := enrichCache[key]; ok {
		t.Fatal("late result after export resurrected key")
	}
}

func TestEnrichCacheSidecarSerializesWriters(t *testing.T) {
	path := setupEnrichPersistenceTest(t)
	writeEnrichDiskTest(t, path, map[string]enrichEntry{})
	loadEnrichCache(path)
	lock, err := enrichCacheLock(path)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	done := make(chan struct{})
	enrichCache["new"] = enrichEntry{Lyrics: "new"}
	enrichDirty = true
	go func() { saveEnrichCache(); close(done) }()
	select {
	case <-done:
		t.Fatal("writer ignored sidecar lock")
	case <-time.After(40 * time.Millisecond):
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("writer did not resume after lock release")
	}
	if _, err := os.Stat(path + ".lock"); err != nil {
		t.Fatal("sidecar removed after atomic rename", err)
	}
}
