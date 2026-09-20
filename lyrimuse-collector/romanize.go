package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const romanizeHelperTimeout = 20 * time.Second

func onDeviceRomanize(lyrics string) (string, error) {
	if lyrics == "" {
		return "", nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	bin := filepath.Join(filepath.Dir(exe), "lyrics-romanize")
	if _, err := os.Stat(bin); err != nil {

		return "", nil
	}
	payload, err := json.Marshal(struct {
		Lyrics string `json:"lyrics"`
	}{Lyrics: lyrics})
	if err != nil {
		return "", fmt.Errorf("marshal romanize request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), romanizeHelperTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin)
	cmd.Stdin = bytes.NewReader(payload)
	out, err := cmd.Output()

	var res struct {
		OK     bool   `json:"ok"`
		Roma   string `json:"roma"`
		Reason string `json:"reason"`
	}
	if jsonErr := json.Unmarshal(out, &res); jsonErr != nil {
		if err != nil {
			return "", fmt.Errorf("run lyrics-romanize: %w", err)
		}
		return "", fmt.Errorf("parse lyrics-romanize output: %w", jsonErr)
	}
	if !res.OK {

		return "", nil
	}
	return res.Roma, nil
}

func (e *enrichEntry) maybeGenerateHelperRoma() {
	if !e.shouldGenerateHelperRoma() {
		return
	}
	roma, err := onDeviceRomanize(e.Lyrics)
	if err != nil || roma == "" {
		return
	}
	e.LyricsRoma = roma
}

func (e *enrichEntry) shouldGenerateHelperRoma() bool {
	if e.Lyrics == "" || e.LyricsRoma != "" {
		return false
	}
	switch dominantScript(e.Lyrics) {
	case scriptHan, scriptKana, scriptHangul:
		return true
	}
	return false
}

func (e *enrichEntry) maybeGenerateRoma() {
	e.maybeGenerateJyutpingRoma()
	e.maybeGenerateHelperRoma()
}
