package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
)

const enrichRestoreSuffix = ".applied"

func adoptEnrichRestore(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var incoming map[string]map[string]json.RawMessage
	if err := json.Unmarshal(data, &incoming); err != nil {

		log.Printf("enrich restore: parse failed, file kept as-is file=%s: %v", filepath.Base(path), err)
		return
	}

	enrichMu.Lock()
	created, mergedInto, skipped := 0, 0, 0
	for key, fields := range incoming {
		if key == "" || len(fields) == 0 {
			skipped++
			continue
		}

		base := map[string]json.RawMessage{}
		if old, ok := enrichCache[key]; ok {
			if b, err := json.Marshal(old); err == nil {
				_ = json.Unmarshal(b, &base)
			}
			mergedInto++
		} else {
			created++
		}
		for field, raw := range fields {
			base[field] = raw
		}

		merged, err := json.Marshal(base)
		if err != nil {
			skipped++
			continue
		}
		var e enrichEntry
		if err := json.Unmarshal(merged, &e); err != nil {
			skipped++
			continue
		}
		enrichCache[key] = e
	}
	if created+mergedInto > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	saveEnrichCache()

	applied := path + enrichRestoreSuffix
	if err := os.Rename(path, applied); err != nil {

		log.Printf("enrich restore: adopted but rename failed (will re-adopt on next start): %v", err)
	}
	log.Printf("enrich restore: adopted entries=%d created=%d merged=%d skipped=%d, renamed to %s",
		created+mergedInto, created, mergedInto, skipped, filepath.Base(applied))
}
