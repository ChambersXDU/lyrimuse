package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os/exec"
	"time"
)

// Stream events only wake the existing authoritative poll; they never update playback state.
func playbackEventWakesPoll(line []byte) bool {
	var event struct {
		Type    string                     `json:"type"`
		Payload map[string]json.RawMessage `json:"payload"`
	}
	if json.Unmarshal(line, &event) != nil || event.Type != "data" {
		return false
	}
	for _, key := range []string{"title", "artist", "album", "playing", "bundleIdentifier"} {
		if _, ok := event.Payload[key]; ok {
			return true
		}
	}
	return false
}

func readPlaybackEvents(ctx context.Context, reader io.Reader, wake chan<- struct{}) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		if ctx.Err() != nil {
			return
		}
		if playbackEventWakesPoll(scanner.Bytes()) {
			select {
			case wake <- struct{}{}:
			default:
			}
		}
	}
}

func watchPlaybackEvents(ctx context.Context, binary string, wake chan<- struct{}) {
	if binary == "" {
		return
	}
	delay := time.Second
	for ctx.Err() == nil {
		started := time.Now()
		streamCtx, cancel := context.WithCancel(ctx)
		cmd := exec.CommandContext(streamCtx, binary, "stream", "--no-artwork")
		// Bound pipe shutdown when a helper inherits the stream's stdout.
		cmd.WaitDelay = time.Second
		reader, err := cmd.StdoutPipe()
		if err == nil {
			err = cmd.Start()
			if err == nil {
				stopClose := context.AfterFunc(ctx, func() { _ = reader.Close() })
				readPlaybackEvents(ctx, reader, wake)
				stopClose()
				cancel()
				_ = cmd.Wait()
			}
			_ = reader.Close()
		}
		cancel()
		if ctx.Err() != nil {
			return
		}
		if time.Since(started) > 30*time.Second {
			delay = time.Second
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		delay = min(delay*2, 30*time.Second)
	}
}
