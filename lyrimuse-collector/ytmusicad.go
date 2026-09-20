package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ytmusicAdVerdict int

const (
	ytmusicAdUnknown ytmusicAdVerdict = iota
	ytmusicAdIsAd
	ytmusicAdIsSong
)

const (
	ytmusicHostMarker = "music.youtube.com"

	ytmusicAdProbeTimeout = 6 * time.Second

	ytmusicAdProbeEventTimeout = 4
)

const ytmusicAdProbeJS = `(function(){` +
	`var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');` +
	`var hasTime = !!document.querySelector('.time-info');` +
	`if (!p && !hasTime) return 'NOTFOUND';` +
	`var cls = p ? (p.className || '') : '';` +
	`var adShowing = cls.indexOf('ad-showing') >= 0 ? '1' : '0';` +
	`var badge = document.querySelector('.ytp-ad-badge, .ytp-ad-simple-ad-badge, .ytp-ad-text, .ytp-ad-preview-container') ? '1' : '0';` +
	`var slotEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');` +
	`var slot = '';` +
	`if (slotEl) { var st = String(slotEl.textContent || '').replace(new RegExp('[0-9]+:[0-9]+', 'g'), ''); var sm = st.match(new RegExp('([0-9]+)[^0-9]{1,12}([0-9]+)')); if (sm) { slot = sm[1] + '/' + sm[2]; } }` +
	`var t = (document.title || '').trim();` +
	`var bare = (t === 'YouTube Music') ? '1' : '0';` +
	`var bl = document.querySelectorAll('ytmusic-player-bar .byline a');` +
	`var album = '';` +
	`for (var i = 0; i < bl.length; i++) {` +
	`var h = bl[i].getAttribute('href') || '';` +
	`if (h.indexOf('browse/MPREb') >= 0) { album = (bl[i].textContent || '').trim(); break; }` +
	`}` +
	`return adShowing + '|' + badge + '|' + bare + '|' + slot + '|' + album;` +
	`})()`

func browserScriptFamily(bundleID string) string {
	switch bundleID {
	case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser":
		return "chromium"
	case "com.apple.Safari":
		return "safari"
	default:
		return ""
	}
}

func parseYTMusicAdProbe(raw string) (ytmusicAdVerdict, string) {
	s := strings.TrimSpace(raw)

	s = strings.Trim(s, "\"")
	s = strings.TrimSpace(s)
	if s == "" || strings.Contains(s, "NOTFOUND") {
		return ytmusicAdUnknown, ""
	}
	parts := strings.SplitN(s, "|", 5)
	if len(parts) < 3 {
		return ytmusicAdUnknown, ""
	}
	ad := false
	for _, p := range parts[:3] {
		switch strings.TrimSpace(p) {
		case "1":
			ad = true
		case "0":

		default:
			return ytmusicAdUnknown, ""
		}
	}
	album := ""
	if len(parts) == 5 {

		album = strings.NewReplacer("\n", " ", "\r", " ").Replace(parts[4])
		album = strings.TrimSpace(album)
	}
	verdict := ytmusicAdIsSong
	if ad {
		verdict = ytmusicAdIsAd
	}
	return verdict, album
}

func parseYTMusicAdVerdict(raw string) ytmusicAdVerdict {
	v, _ := parseYTMusicAdProbe(raw)
	return v
}

func ytmusicAlbumPatch(reported string, verdict ytmusicAdVerdict, probed string) string {
	if strings.TrimSpace(reported) != "" {
		return ""
	}
	if verdict != ytmusicAdIsSong {
		return ""
	}
	return strings.TrimSpace(probed)
}

func buildYTMusicAdAppleScript(bundleID, family string) string {
	var activeTab, executeActive, executeTab string
	switch family {
	case "chromium":
		activeTab = "active tab of window wi"
		executeActive = "execute (active tab of window wi) javascript \"" + ytmusicAdProbeJS + "\""
		executeTab = "execute (tab ti of window wi) javascript \"" + ytmusicAdProbeJS + "\""
	case "safari":
		activeTab = "current tab of window wi"
		executeActive = "do JavaScript \"" + ytmusicAdProbeJS + "\" in current tab of window wi"
		executeTab = "do JavaScript \"" + ytmusicAdProbeJS + "\" in tab ti of window wi"
	default:
		return ""
	}
	t := strconv.Itoa(ytmusicAdProbeEventTimeout)
	return "tell application id \"" + bundleID + "\"\n" +
		"\tset winCount to count of windows\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\ttry\n" +
		"\t\t\tif (URL of " + activeTab + ") contains \"" + ytmusicHostMarker + "\" then\n" +
		"\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\tset r to " + executeActive + "\n" +
		"\t\t\t\tend timeout\n" +
		"\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\treturn r\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend if\n" +
		"\t\tend try\n" +
		"\tend repeat\n" +
		"\trepeat with wi from 1 to winCount\n" +
		"\t\tset tabCount to count of tabs of window wi\n" +
		"\t\trepeat with ti from 1 to tabCount\n" +
		"\t\t\ttry\n" +
		"\t\t\t\tif (URL of tab ti of window wi) contains \"" + ytmusicHostMarker + "\" then\n" +
		"\t\t\t\t\twith timeout of " + t + " seconds\n" +
		"\t\t\t\t\t\tset r to " + executeTab + "\n" +
		"\t\t\t\t\tend timeout\n" +
		"\t\t\t\t\tif r does not contain \"NOTFOUND\" then\n" +
		"\t\t\t\t\t\treturn r\n" +
		"\t\t\t\t\tend if\n" +
		"\t\t\t\tend if\n" +
		"\t\t\tend try\n" +
		"\t\tend repeat\n" +
		"\tend repeat\n" +
		"\treturn \"NOTFOUND\"\n" +
		"end tell\n"
}

const ytmusicAdMaxAge = 60 * time.Second

const ytmusicAdRefreshWhenAd = 5 * time.Second

func ytmusicAdReuseWindow(v ytmusicAdVerdict) time.Duration {
	if v == ytmusicAdIsAd {
		return ytmusicAdRefreshWhenAd
	}
	return ytmusicAdMaxAge
}

var (
	ytmusicAdMu    sync.Mutex
	ytmusicAdKey   string
	ytmusicAdVal   ytmusicAdVerdict
	ytmusicAdAlbum string
	ytmusicAdAt    time.Time
)

func ytmusicAdProbe(ctx context.Context, bundleID, trackKey string) (ytmusicAdVerdict, string) {

	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" {
		return ytmusicAdUnknown, ""
	}

	cacheKey := target + "\x00" + trackKey
	ytmusicAdMu.Lock()
	if ytmusicAdKey == cacheKey && time.Since(ytmusicAdAt) < ytmusicAdReuseWindow(ytmusicAdVal) {
		v, al := ytmusicAdVal, ytmusicAdAlbum
		ytmusicAdMu.Unlock()
		return v, al
	}
	ytmusicAdMu.Unlock()

	v, album := runYTMusicAdProbe(ctx, target, family)

	ytmusicAdMu.Lock()

	if v != ytmusicAdUnknown {
		ytmusicAdKey, ytmusicAdVal, ytmusicAdAlbum, ytmusicAdAt = cacheKey, v, album, time.Now()
	}
	ytmusicAdMu.Unlock()
	return v, album
}

func runYTMusicAdProbe(ctx context.Context, bundleID, family string) (ytmusicAdVerdict, string) {
	script := buildYTMusicAdAppleScript(bundleID, family)
	if script == "" {
		return ytmusicAdUnknown, ""
	}
	f, err := os.CreateTemp("", "lyrimuse-ytmusic-ad-*.applescript")
	if err != nil {
		return ytmusicAdUnknown, ""
	}
	path := f.Name()
	defer os.Remove(path)
	if _, err := f.WriteString(script); err != nil {
		f.Close()
		return ytmusicAdUnknown, ""
	}
	if err := f.Close(); err != nil {
		return ytmusicAdUnknown, ""
	}

	ctx, cancel := context.WithTimeout(ctx, ytmusicAdProbeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", filepath.Clean(path)).Output()
	if err != nil {

		return ytmusicAdUnknown, ""
	}
	return parseYTMusicAdProbe(string(out))
}

func trustedPlaybackRejected(ctx context.Context, bundleID, artist, album, title string) (bool, string) {
	if !trustedPlaybackNotASong(bundleID, artist, album) {
		return false, ""
	}
	if strings.TrimSpace(artist) == "" {
		return true, ""
	}
	trackKey := strings.TrimSpace(artist) + "\x00" + strings.TrimSpace(title)
	verdict, probedAlbum := ytmusicAdProbe(ctx, bundleID, trackKey)
	switch verdict {
	case ytmusicAdIsSong:
		return false, ytmusicAlbumPatch(album, verdict, probedAlbum)
	case ytmusicAdIsAd:

		log.Printf("ytmusic: rejected as advertisement (%s - %s)", artist, title)
		return true, ""
	default:
		return true, ""
	}
}
