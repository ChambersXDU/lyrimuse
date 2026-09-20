package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
)

var lyricsTraceMu sync.Mutex

const lyricsTraceMaxBytes = 2 << 20

func traceLyricsDecision(key string, d *lyricsDecision) {
	if d == nil || !features.LyricsDecisionTrace {
		return
	}
	if enrichPath == "" {

		return
	}
	rec := struct {
		Key string `json:"key"`
		*lyricsDecision
	}{key, d}
	blob, err := json.Marshal(rec)
	if err != nil {
		log.Printf("lyrics trace: marshal: %v", err)
		return
	}
	path := filepath.Join(filepath.Dir(enrichPath), clientName+"-lyrics-decision-trace.ndjson")

	lyricsTraceMu.Lock()
	defer lyricsTraceMu.Unlock()
	if st, err := os.Stat(path); err == nil && st.Size() > lyricsTraceMaxBytes {

		if err := os.Rename(path, path+".old"); err != nil {
			log.Printf("lyrics trace: rotate: %v", err)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("lyrics trace: open: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(blob, '\n')); err != nil {
		log.Printf("lyrics trace: write: %v", err)
	}
}
