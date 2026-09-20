package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sync"
	"syscall"
	"time"
)

var enrichSaveMu sync.Mutex
var enrichExternalGeneration = map[string]uint64{}

// enrichCacheLock is a permanent sidecar lock. Keeping it separate from the
// cache itself means an atomic cache rename cannot replace the inode Swift is
// locking.
func enrichCacheLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			_ = f.Close()
			return nil, err
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("timed out locking enrich cache")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func unlockEnrichCache(f *os.File) error {
	if f == nil {
		return nil
	}
	unlockErr := syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	closeErr := f.Close()
	if unlockErr != nil {
		return unlockErr
	}
	return closeErr
}

// readEnrichCacheDisk reads the cache while its sidecar lock is held. A
// missing file is an empty cache; an existing malformed file is an error so
// save cannot silently replace a protected/corrupt user file.
func readEnrichCacheDisk(path string) (map[string]enrichEntry, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]enrichEntry{}, nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	if m == nil {
		return nil, fmt.Errorf("cache JSON is null")
	}
	return m, nil
}

func cloneLyricsDecision(in *lyricsDecision) *lyricsDecision {
	if in == nil {
		return nil
	}
	out := *in
	out.SourcesResponded = slices.Clone(in.SourcesResponded)
	out.SourcesSkipped = slices.Clone(in.SourcesSkipped)
	out.Candidates = slices.Clone(in.Candidates)
	for i := range out.Candidates {
		out.Candidates[i].ScoreTerms = slices.Clone(in.Candidates[i].ScoreTerms)
		out.Candidates[i].ConsensusPeers = slices.Clone(in.Candidates[i].ConsensusPeers)
	}
	out.QueriesTried = slices.Clone(in.QueriesTried)
	for i := range out.QueriesTried {
		out.QueriesTried[i].Sources = slices.Clone(in.QueriesTried[i].Sources)
	}
	return &out
}

func cloneEnrichEntry(in enrichEntry) enrichEntry {
	out := in
	out.LyricsSourcesSeen = slices.Clone(in.LyricsSourcesSeen)
	out.LyricsSourcesResponded = slices.Clone(in.LyricsSourcesResponded)
	out.LyricsSourcesSkipped = slices.Clone(in.LyricsSourcesSkipped)
	out.LyricsSourcesFailed = slices.Clone(in.LyricsSourcesFailed)
	out.LyricsDecision = cloneLyricsDecision(in.LyricsDecision)
	out.LyricsDecisionApplied = cloneLyricsDecision(in.LyricsDecisionApplied)
	if in.Unknown != nil {
		out.Unknown = make(map[string]json.RawMessage, len(in.Unknown))
		for k, v := range in.Unknown {
			out.Unknown[k] = slices.Clone(v)
		}
	}
	return out
}

func cloneEnrichMap(in map[string]enrichEntry) map[string]enrichEntry {
	if in == nil {
		return map[string]enrichEntry{}
	}
	out := make(map[string]enrichEntry, len(in))
	for k, v := range in {
		out[k] = cloneEnrichEntry(v)
	}
	return out
}

func enrichEntryEqual(a enrichEntry, aOK bool, b enrichEntry, bOK bool) bool {
	if aOK != bOK {
		return false
	}
	if !aOK {
		return true
	}
	return reflect.DeepEqual(a, b)
}

// External changes win conflicts, including deletion, while unrelated local fields survive.
func mergeEnrichCache(baseline, current, disk map[string]enrichEntry) (map[string]enrichEntry, error) {
	merged := make(map[string]enrichEntry, len(current)+len(disk))
	for key, value := range current {
		merged[key] = value
	}
	keys := make(map[string]bool, len(baseline)+len(disk))
	for key := range baseline {
		keys[key] = true
	}
	for key := range disk {
		keys[key] = true
	}
	for key := range keys {
		b, bok := baseline[key]
		d, dok := disk[key]
		if enrichEntryEqual(b, bok, d, dok) {
			continue
		}
		if !dok {
			delete(merged, key)
			continue
		}
		m, mok := current[key]
		if !bok || !mok || reflect.DeepEqual(m, b) {
			merged[key] = d
			continue
		}
		fields := make([]map[string]json.RawMessage, 3)
		for i, value := range []enrichEntry{b, m, d} {
			data, err := json.Marshal(value)
			if err != nil {
				return nil, err
			}
			if err := json.Unmarshal(data, &fields[i]); err != nil {
				return nil, err
			}
		}
		changed := map[string]bool{}
		for field := range fields[0] {
			changed[field] = true
		}
		for field := range fields[2] {
			changed[field] = true
		}
		for field := range changed {
			if bytes.Equal(fields[0][field], fields[2][field]) {
				continue
			}
			if value, exists := fields[2][field]; exists {
				fields[1][field] = value
			} else {
				delete(fields[1], field)
			}
		}
		data, err := json.Marshal(fields[1])
		if err != nil {
			return nil, err
		}
		var value enrichEntry
		if err := json.Unmarshal(data, &value); err != nil {
			return nil, err
		}
		merged[key] = value
	}
	return merged, nil
}

// Called with enrichMu held, before advancing the disk baseline.
func noteExternalEnrichChanges(baseline, disk map[string]enrichEntry) {
	keys := map[string]bool{}
	for key := range baseline {
		keys[key] = true
	}
	for key := range disk {
		keys[key] = true
	}
	for key := range keys {
		b, bok := baseline[key]
		d, dok := disk[key]
		if !enrichEntryEqual(b, bok, d, dok) {
			enrichExternalGeneration[key]++
		}
	}
}

func loadEnrichCache(path string) {
	enrichSaveMu.Lock()
	defer enrichSaveMu.Unlock()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	enrichPath = path
	if enrichBaselinePath != path {
		enrichBaseline = nil
		enrichBaselineReady = false
		enrichBaselinePath = path
	}
	lock, err := enrichCacheLock(path)
	if err != nil {
		log.Printf("load enrich cache lock: %v", err)
		return
	}
	defer func() {
		if err := unlockEnrichCache(lock); err != nil {
			log.Printf("unlock enrich cache: %v", err)
		}
	}()
	m, err := readEnrichCacheDisk(path)
	if err != nil {
		var pathError *os.PathError
		if errors.As(err, &pathError) {
			log.Printf("load enrich cache: %v — existing file left untouched", err)
			return
		}
		if !os.IsNotExist(err) {
			side := path + ".corrupt"
			if renameErr := os.Rename(path, side); renameErr == nil {
				log.Printf("enrich cache unreadable (%v) — moved aside to %s, starting empty", err, side)
			} else {
				log.Printf("enrich cache unreadable (%v) and could not move aside (%v)", err, renameErr)
			}
		}
		return
	}
	enrichCache = m
	enrichExternalGeneration = map[string]uint64{}
	enrichBaseline = cloneEnrichMap(m)
	enrichBaselinePath = path
	enrichBaselineReady = true
	enrichDirty = false
	log.Printf("cache: loaded %d track enrichments from %s", len(m), path)
	warnEnrichUnknownKeys(m)
}

func writeEnrichCacheAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

func saveEnrichCache() {
	enrichSaveMu.Lock()
	defer enrichSaveMu.Unlock()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if !enrichDirty || enrichPath == "" {
		return
	}
	path := enrichPath
	lock, err := enrichCacheLock(path)
	if err != nil {
		log.Printf("save enrich cache lock: %v", err)
		return
	}
	defer func() {
		if err := unlockEnrichCache(lock); err != nil {
			log.Printf("unlock enrich cache: %v", err)
		}
	}()
	disk, err := readEnrichCacheDisk(path)
	if err != nil {
		log.Printf("save enrich cache: read latest cache: %v", err)
		return
	}
	baseline := enrichBaseline
	if !enrichBaselineReady || enrichBaselinePath != path {
		baseline = map[string]enrichEntry{}
	}
	merged, err := mergeEnrichCache(baseline, enrichCache, disk)
	if err != nil {
		log.Printf("save enrich cache merge: %v", err)
		return
	}
	data, err := json.Marshal(merged)
	if err != nil {
		log.Printf("save enrich cache: %v", err)
		return
	}
	var savedBaseline map[string]enrichEntry
	if err := json.Unmarshal(data, &savedBaseline); err != nil {
		log.Printf("save enrich cache baseline: %v", err)
		return
	}
	if err := writeEnrichCacheAtomic(path, data); err != nil {
		log.Printf("save enrich cache: %v", err)
		return
	}
	noteExternalEnrichChanges(baseline, disk)
	enrichCache = merged
	enrichBaseline = savedBaseline
	enrichBaselinePath = path
	enrichBaselineReady = true
	enrichDirty = false
}
