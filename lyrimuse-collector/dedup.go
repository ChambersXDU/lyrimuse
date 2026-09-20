package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"
)

type persistedTTLSet struct {
	path string
	ttl  time.Duration
}

func (s persistedTTLSet) load() (map[int64]bool, bool) {
	m := map[int64]bool{}
	if s.path == "" {
		return m, false
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return m, false
	}
	var arr []int64
	if json.Unmarshal(b, &arr) == nil {
		for _, u := range arr {
			m[u] = true
		}
	}
	return m, true
}

func (s persistedTTLSet) save(m map[int64]bool) {
	if s.path == "" {
		return
	}
	arr := make([]int64, 0, len(m))
	for u := range m {
		arr = append(arr, u)
	}
	data, err := json.Marshal(arr)
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		log.Printf("save %s: %v", filepath.Base(s.path), err)
	}
}

func (s persistedTTLSet) trim(m map[int64]bool, now time.Time) bool {
	cutoff := now.Unix() - int64(s.ttl/time.Second)
	changed := false
	for u := range m {
		if u < cutoff {
			delete(m, u)
			changed = true
		}
	}
	return changed
}

const forwardedTTL = 7 * 24 * time.Hour

var forwardedPath string

const lfmMirroredTTL = 7 * 24 * time.Hour

var lfmMirroredPath string

var lastfmStatusPath string
