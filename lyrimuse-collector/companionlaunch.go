package main

import (
	"bufio"
	"bytes"
	"context"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var (
	lastRunningByName   = map[string]bool{}
	wasCompanionEnabled = false
)

const companionLaunchInterval = 3 * time.Second

func startCompanionLaunchWatcher(ctx context.Context) {
	ticker := time.NewTicker(companionLaunchInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			if !features.LaunchLyrimuseOnMusicOpen {
				wasCompanionEnabled = false
				clear(lastRunningByName)
				continue
			}
			checkCompanionLaunch(ctx)
		}
	}
}

func batchRunningProcesses(ctx context.Context, names []string) (map[string]bool, error) {
	running := make(map[string]bool, len(names))
	if len(names) == 0 {
		return running, nil
	}
	escaped := make([]string, len(names))
	for i, name := range names {
		escaped[i] = regexp.QuoteMeta(name)
	}
	pattern := strings.Join(escaped, "|")
	cmdCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	out, err := exec.CommandContext(cmdCtx, "pgrep", "-l", "-x", pattern).Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {

			return running, nil
		}
		return running, err
	}

	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			procName := strings.TrimSpace(line[len(fields[0]):])
			for _, candidate := range names {
				if candidate == procName {
					running[candidate] = true
					break
				}
			}
		}
	}
	return running, nil
}

func checkCompanionLaunch(ctx context.Context) {
	if !features.LaunchLyrimuseOnMusicOpen {
		wasCompanionEnabled = false
		clear(lastRunningByName)
		return
	}

	names := companionLaunchProcessNames()
	if len(names) == 0 {
		return
	}

	runningMap, err := batchRunningProcesses(ctx, names)
	if err != nil {
		log.Printf("companion launch: error querying running processes: %v", err)
		return
	}

	if !wasCompanionEnabled {
		wasCompanionEnabled = true
		for _, name := range names {
			lastRunningByName[name] = runningMap[name]
		}
		return
	}

	var justStarted string
	for _, name := range names {
		running := runningMap[name]
		if running && !lastRunningByName[name] && justStarted == "" {
			justStarted = name
		}
		lastRunningByName[name] = running
	}

	alreadyRunning := false
	if !shouldCompanionLaunch(justStarted, features.LaunchLyrimuseOnMusicOpen, func() bool {
		alreadyRunning = isProcessRunning(lyrimuseAppProcessName)
		return alreadyRunning
	}) {
		if alreadyRunning {
			log.Printf("companion launch: %s just started, Lyrimuse.app already running, skipping", justStarted)
		}
		return
	}
	log.Printf("companion launch: %s just started, launching Lyrimuse.app", justStarted)
	launchLyrimuseApp()
}

const lyrimuseAppProcessName = "lyrimuse"

func shouldCompanionLaunch(justStarted string, enabled bool, lyrimuseRunning func() bool) bool {
	if justStarted == "" || !enabled {
		return false
	}
	return !lyrimuseRunning()
}

func isProcessRunning(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", name).Run() == nil
}

func companionLaunchProcessNames() []string {
	var candidates []string
	if features.Players[playerAuto] {
		candidates = knownPlayerProcessNames
	} else {
		candidates = make([]string, 0, len(features.Players))
		for player := range features.Players {
			candidates = append(candidates, playerProcessNameFor(player))
		}
	}

	if features.LaunchLyrimuseOnPlayers == nil {
		return candidates
	}
	names := make([]string, 0, len(features.LaunchLyrimuseOnPlayers))
	for player := range features.LaunchLyrimuseOnPlayers {
		name := playerProcessNameFor(player)
		for _, candidate := range candidates {
			if candidate == name {
				names = append(names, name)
				break
			}
		}
	}
	return names
}

var knownPlayerProcessNames = []string{"Music", "QQMusic", "NeteaseMusic", "Spotify", "酷狗音乐"}

func playerProcessNameFor(player string) string {
	switch player {
	case playerQQMusic:
		return "QQMusic"
	case playerNetease:
		return "NeteaseMusic"
	case playerSpotify:
		return "Spotify"
	case playerKugou:
		return "酷狗音乐"
	default:
		return "Music"
	}
}

func launchLyrimuseApp() {
	if isProcessRunning(lyrimuseAppProcessName) {
		return
	}

	if err := exec.Command("open", "--background", "-b", appBundleID()).Start(); err != nil {
		log.Printf("companion launch: failed to open Lyrimuse.app: %v", err)
	}
}
