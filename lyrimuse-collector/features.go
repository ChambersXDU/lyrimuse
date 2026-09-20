package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
)

const (
	lyricSourceNetease    = "netease"
	lyricSourceQQ         = "qq"
	lyricSourceKugou      = "kugou"
	lyricSourceMusixmatch = "musixmatch"
	lyricSourceLRCLIB     = "lrclib"

	lyricSourceAMLL = "amll"

	lyricSourceLyricFind = "lyricfind"

	lyricSourceKuwo = "kuwo"

	lyricSourceMigu = "migu"

	lyricSourceDeezer = "deezer"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

const (
	playerAppleMusic = "apple_music"
	playerQQMusic    = "qq_music"
	playerNetease    = "netease_music"
	playerSpotify    = "spotify"

	playerKugou = "kugou_music"
	playerAuto  = "auto"
)

var lyricsSourceDefaultOrder = []string{
	lyricSourceKugou, lyricSourceNetease, lyricSourceQQ, lyricSourceMusixmatch, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
}

type featureFlagsFile struct {
	Player string `json:"player,omitempty"`

	Players       []string `json:"players,omitempty"`
	AlbumPrefetch *bool    `json:"album_prefetch,omitempty"`

	LyricsAutoUpgrade *bool `json:"lyrics_auto_upgrade,omitempty"`
	WeeklyDigest      *bool `json:"weekly_digest,omitempty"`

	DailyDigest *bool `json:"daily_digest,omitempty"`

	WeeklyDigestSource string `json:"weekly_digest_source,omitempty"`
	DailyDigestSource  string `json:"daily_digest_source,omitempty"`

	LyricsSources []string `json:"lyrics_sources,omitempty"`

	AMLLLyrics *bool `json:"amll_lyrics,omitempty"`

	LyricFindLyrics *bool `json:"lyricfind_lyrics,omitempty"`

	KuwoLyrics *bool `json:"kuwo_lyrics,omitempty"`

	MiguLyrics *bool `json:"migu_lyrics,omitempty"`

	DeezerLyrics *bool `json:"deezer_lyrics,omitempty"`

	LyricsSourceMode string `json:"lyrics_source_mode,omitempty"`

	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`

	LyricsDir string `json:"lyrics_dir,omitempty"`

	LyricsTranslationLanguage string `json:"lyrics_translation_language,omitempty"`

	LyricsMachineTranslation *bool `json:"lyrics_machine_translation,omitempty"`

	LaunchLyrimuseOnMusicOpen *bool `json:"launch_lyrimuse_on_music_open,omitempty"`

	LaunchLyrimuseOnPlayers []string `json:"launch_lyrimuse_on_players,omitempty"`

	TrustedPlayers map[string]string `json:"trusted_players,omitempty"`

	LyricsDecisionTrace *bool `json:"lyrics_decision_trace,omitempty"`
}

type featureFlags struct {
	Players       map[string]bool
	AlbumPrefetch bool

	LyricsAutoUpgrade  bool
	WeeklyDigest       bool
	DailyDigest        bool
	WeeklyDigestSource string
	DailyDigestSource  string

	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string

	LyricsDir string

	LyricsTranslationLanguage string

	LyricsMachineTranslation bool

	LaunchLyrimuseOnMusicOpen bool

	LaunchLyrimuseOnPlayers map[string]bool

	LyricsDecisionTrace bool

	TrustedPlayers map[string]string
}

var (
	featuresMu sync.RWMutex
	features   featureFlags
)

func resolveLaunchLyrimuseOnPlayers(raw []string) map[string]bool {
	if raw == nil {
		return nil
	}
	out := map[string]bool{}
	for _, p := range raw {
		switch p {
		case playerAppleMusic, playerQQMusic, playerNetease, playerKugou, playerSpotify:
			out[p] = true
		}
	}
	return out
}

func boolOr(p *bool, def bool) bool {
	if p == nil {
		return def
	}
	return *p
}

func loadFeatureFlags(path string) featureFlags {
	var f featureFlagsFile
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &f); jerr != nil {
			log.Printf("parse feature flags %s: %v (falling back to defaults)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (falling back to defaults)", path, err)
	}
	return featureFlags{
		Players:        resolvePlayers(f.Players, f.Player),
		TrustedPlayers: resolveTrustedPlayers(f.TrustedPlayers),

		AlbumPrefetch: boolOr(f.AlbumPrefetch, true),

		LyricsAutoUpgrade:         boolOr(f.LyricsAutoUpgrade, true),
		WeeklyDigest:              boolOr(f.WeeklyDigest, false),
		DailyDigest:               boolOr(f.DailyDigest, false),
		WeeklyDigestSource:        f.WeeklyDigestSource,
		DailyDigestSource:         f.DailyDigestSource,
		LyricsSources:             resolveLyricsSources(f.LyricsSources, f.AMLLLyrics, f.LyricFindLyrics, f.KuwoLyrics, f.MiguLyrics, f.DeezerLyrics),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage),
		LyricsMachineTranslation:  boolOr(f.LyricsMachineTranslation, false),
		LaunchLyrimuseOnMusicOpen: boolOr(f.LaunchLyrimuseOnMusicOpen, true),
		LaunchLyrimuseOnPlayers:   resolveLaunchLyrimuseOnPlayers(f.LaunchLyrimuseOnPlayers),
		LyricsDecisionTrace:       boolOr(f.LyricsDecisionTrace, false),
	}
}

func isValidPlayerValue(p string) bool {
	switch p {
	case playerAppleMusic, playerQQMusic, playerNetease, playerSpotify, playerKugou, playerAuto:
		return true
	default:
		return false
	}
}

func resolvePlayers(list []string, legacy string) map[string]bool {
	m := map[string]bool{}
	for _, p := range list {
		if isValidPlayerValue(p) {
			m[p] = true
		}
	}
	if len(m) > 0 {
		return m
	}
	if isValidPlayerValue(legacy) {
		return map[string]bool{legacy: true}
	}
	return map[string]bool{playerAuto: true}
}

func resolveTrustedPlayers(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	builtin := map[string]bool{
		"com.apple.Music": true, qqMusicBundleID: true,
		neteaseMusicBundleID: true, spotifyBundleID: true, kugouMusicBundleID: true,
	}
	out := make(map[string]string, len(m))
	for bundleID, name := range m {
		id := strings.TrimSpace(bundleID)
		if id == "" || builtin[id] {
			continue
		}
		out[id] = strings.TrimSpace(name)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func resolveLyricsSources(list []string, amllSeen *bool, lyricFindSeen *bool, kuwoSeen *bool, miguSeen *bool, deezerSeen *bool) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{
			lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
			lyricSourceMusixmatch: true, lyricSourceLRCLIB: true,
			lyricSourceAMLL: true, lyricSourceLyricFind: true, lyricSourceKuwo: true, lyricSourceMigu: true,
			lyricSourceDeezer: true,
		}
	}
	m := make(map[string]bool, len(list)+1)
	for _, s := range list {
		m[s] = true
	}

	if amllSeen == nil {
		m[lyricSourceAMLL] = true
	}
	if lyricFindSeen == nil {
		m[lyricSourceLyricFind] = true
	}
	if kuwoSeen == nil {
		m[lyricSourceKuwo] = true
	}
	if miguSeen == nil {
		m[lyricSourceMigu] = true
	}
	if deezerSeen == nil {
		m[lyricSourceDeezer] = true
	}
	return m
}

func lyricSourceEnabled(source string) bool {
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	return len(features.LyricsSources) == 0 || features.LyricsSources[source]
}

func getFeaturesLyricsSources() map[string]bool {
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	if features.LyricsSources == nil {
		return nil
	}
	out := make(map[string]bool, len(features.LyricsSources))
	for k, v := range features.LyricsSources {
		out[k] = v
	}
	return out
}

func setFeaturesLyricsSources(m map[string]bool) {
	featuresMu.Lock()
	defer featuresMu.Unlock()
	if m == nil {
		features.LyricsSources = nil
		return
	}
	out := make(map[string]bool, len(m))
	for k, v := range m {
		out[k] = v
	}
	features.LyricsSources = out
}

func resolveLyricsSourceMode(mode string) string {
	if mode == lyricsModePriority {
		return lyricsModePriority
	}
	return lyricsModeSmart
}

func resolveLyricsSourceOrder(order []string) []string {
	if len(order) == 0 {
		return append([]string(nil), lyricsSourceDefaultOrder...)
	}
	return order
}

func resolveLyricsTranslationLanguage(lang string) string {
	if lang != "" && lang != "auto" {
		return lang
	}
	if code := systemLanguageCode(); code != "" {
		return code
	}
	return "en"
}

func systemLanguageCode() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleLocale").Output()
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(out))
	if i := strings.IndexByte(s, '_'); i > 0 {
		s = s[:i]
	}
	if s == "" {
		return ""
	}
	return strings.ToLower(s)
}
