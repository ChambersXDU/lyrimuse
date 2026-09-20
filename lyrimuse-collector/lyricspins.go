package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"
)

type lyricsPinsFile struct {
	Version int `json:"version"`

	Pins map[string]int64 `json:"pins"`
}

var (

	lyricsPinsPath  string
	lyricsPinsMu    sync.Mutex
	lyricsPins      map[string]bool
	lyricsPinsMTime time.Time
	lyricsPinsSize  int64
	lyricsPinsRead  bool
)

func lyricsPinned(key string) bool {
	if lyricsPinsPath == "" || key == "" {
		return false
	}
	lyricsPinsMu.Lock()
	defer lyricsPinsMu.Unlock()
	st, err := os.Stat(lyricsPinsPath)
	if err != nil {

		lyricsPins, lyricsPinsRead = nil, true
		lyricsPinsMTime, lyricsPinsSize = time.Time{}, 0
		return false
	}
	if !lyricsPinsRead || !st.ModTime().Equal(lyricsPinsMTime) || st.Size() != lyricsPinsSize {
		lyricsPins = readLyricsPins(lyricsPinsPath)
		lyricsPinsMTime, lyricsPinsSize, lyricsPinsRead = st.ModTime(), st.Size(), true
	}
	return lyricsPins[key]
}

func readLyricsPins(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var f lyricsPinsFile
	if err := json.Unmarshal(data, &f); err != nil {
		log.Printf("lyrics pins: cannot parse %s, treating as empty: %v", path, err)
		return nil
	}
	out := make(map[string]bool, len(f.Pins))
	for k := range f.Pins {
		if k != "" {
			out[k] = true
		}
	}
	return out
}
