package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"
)

var (
	collectorStatusPath string
	collectorStatusMu   sync.Mutex

	collectorStatusNetworkDown bool
)

type collectorStatusFile struct {

	NetworkDown bool  `json:"networkDown"`
	At          int64 `json:"at"`
}

func setCollectorStatusPath(path string) {
	collectorStatusMu.Lock()
	collectorStatusPath = path
	collectorStatusMu.Unlock()

	clearCollectorNetworkDown()
}

func markCollectorNetworkDown() {
	collectorStatusMu.Lock()
	defer collectorStatusMu.Unlock()
	if collectorStatusPath == "" || collectorStatusNetworkDown {
		return
	}
	data, err := json.Marshal(collectorStatusFile{NetworkDown: true, At: time.Now().Unix()})
	if err != nil {
		return
	}
	if err := os.WriteFile(collectorStatusPath, data, 0o644); err != nil {
		log.Printf("collector status: write failed: %v", err)
		return
	}
	collectorStatusNetworkDown = true
	log.Printf("collector status: network down, every lyric source failed this round")
}

func clearCollectorNetworkDown() {
	collectorStatusMu.Lock()
	defer collectorStatusMu.Unlock()
	if collectorStatusPath == "" {
		return
	}

	if err := os.Remove(collectorStatusPath); err != nil && !os.IsNotExist(err) {
		log.Printf("collector status: clear failed: %v", err)
	}
	if collectorStatusNetworkDown {
		log.Printf("collector status: network restored")
	}
	collectorStatusNetworkDown = false
}
