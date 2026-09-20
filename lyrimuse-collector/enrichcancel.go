package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"
)

var enrichCancelRequestPath string

func setEnrichCancelRequestPath(path string) {
	enrichCancelRequestPath = path
	_ = os.Remove(path)
}

const enrichCancelCheckInterval = 2 * time.Second

func startEnrichCancelWatcher(ctx context.Context) {
	if enrichCancelRequestPath == "" {
		return
	}
	ticker := time.NewTicker(enrichCancelCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			checkEnrichCancelRequest()
		}
	}
}

func checkEnrichCancelRequest() {
	if enrichCancelRequestPath == "" {
		return
	}
	if _, err := os.Stat(enrichCancelRequestPath); err != nil {
		return
	}
	data, err := os.ReadFile(enrichCancelRequestPath)
	if err != nil {
		return
	}
	_ = os.Remove(enrichCancelRequestPath)
	key := strings.TrimSpace(string(data))
	if key == "" {
		return
	}
	enrichMu.Lock()
	cancel, ok := enrichCancelFuncs[key]
	enrichMu.Unlock()
	if !ok {

		log.Printf("enrich cancel: no in-flight search found for key=%q (already finished, or never started)", key)
		return
	}
	log.Printf("enrich cancel: cancelling in-flight search for key=%q", key)
	cancel()
}
