package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type listenLogLine struct {

	T string `json:"t"`

	V int `json:"v"`

	UTS int64 `json:"uts"`

	AR string `json:"ar"`
	TI string `json:"ti"`
	AL string `json:"al,omitempty"`

	DUR float64 `json:"dur,omitempty"`

	AT int64 `json:"at"`

	M int `json:"m,omitempty"`
}

const listenLogSchemaVersion = 1

var (
	listenLogPath string
	listenLogMu   sync.Mutex
)

const (
	listenLogMaxLines  = 40000
	listenLogKeepLines = 30000
)

func initListenLog(path string) {
	listenLogMu.Lock()
	listenLogPath = path
	listenLogMu.Unlock()
	compactListenLog()
}

func appendListen(artist, title, album string, uts int64, durationSecs float64) {
	if uts <= 0 || title == "" {
		return
	}
	appendListenLogLine(listenLogLine{
		T: "l", V: listenLogSchemaVersion, UTS: uts,
		AR: artist, TI: title, AL: album,
		DUR: durationSecs, AT: time.Now().Unix(),
	})
}

func appendListenLogLine(line listenLogLine) {
	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	if listenLogPath == "" {
		return
	}
	data, err := json.Marshal(line)
	if err != nil {
		log.Printf("listen log: marshal failed: %v", err)
		return
	}

	if err := os.MkdirAll(filepath.Dir(listenLogPath), 0o755); err != nil {
		log.Printf("listen log: mkdir failed: %v", err)
		return
	}

	f, err := os.OpenFile(listenLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("listen log: open failed: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(data, '\n')); err != nil {
		log.Printf("listen log: write failed: %v", err)
	}
}

func readListenLog() []listenLogLine {
	listenLogMu.Lock()
	path := listenLogPath
	listenLogMu.Unlock()
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []listenLogLine
	sc := bufio.NewScanner(f)

	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	bad := 0
	for sc.Scan() {
		raw := sc.Bytes()
		if len(raw) == 0 {
			continue
		}
		var line listenLogLine
		if err := json.Unmarshal(raw, &line); err != nil {
			bad++
			continue
		}
		out = append(out, line)
	}
	if bad > 0 {
		log.Printf("listen log: skipped %d unparseable line(s)", bad)
	}
	return out
}

func compactListenLog() {
	lines := readListenLog()
	if len(lines) <= listenLogMaxLines {
		return
	}
	keep := lines[len(lines)-listenLogKeepLines:]

	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	tmp := listenLogPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("listen log: compact open failed: %v", err)
		return
	}
	w := bufio.NewWriter(f)
	for _, line := range keep {
		data, err := json.Marshal(line)
		if err != nil {
			continue
		}
		w.Write(append(data, '\n'))
	}
	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		log.Printf("listen log: compact flush failed: %v", err)
		return
	}
	f.Close()

	if err := os.Rename(tmp, listenLogPath); err != nil {
		os.Remove(tmp)
		log.Printf("listen log: compact rename failed: %v", err)
		return
	}
	log.Printf("listen log: compacted %d lines -> %d", len(lines), len(keep))
}
