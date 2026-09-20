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
	lyricSourceAMLL       = "amll"
	lyricSourceLyricFind  = "lyricfind"
	lyricSourceKuwo       = "kuwo"
	lyricSourceMigu       = "migu"
	lyricSourceDeezer     = "deezer"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

var lyricsSourceDefaultOrder = []string{
	lyricSourceKugou, lyricSourceNetease, lyricSourceQQ, lyricSourceMusixmatch, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
}

// This is only lyric-search configuration. Player selection, notifications,
// cloud relay and diagnostic switches do not belong in the collector anymore.
type featureFlagsFile struct {
	AlbumPrefetch     *bool `json:"album_prefetch,omitempty"`
	LyricsAutoUpgrade *bool `json:"lyrics_auto_upgrade,omitempty"`
	LyricsSources     []string `json:"lyrics_sources,omitempty"`

	AMLLLyrics      *bool `json:"amll_lyrics,omitempty"`
	LyricFindLyrics *bool `json:"lyricfind_lyrics,omitempty"`
	KuwoLyrics      *bool `json:"kuwo_lyrics,omitempty"`
	MiguLyrics      *bool `json:"migu_lyrics,omitempty"`
	DeezerLyrics    *bool `json:"deezer_lyrics,omitempty"`

	LyricsSourceMode  string   `json:"lyrics_source_mode,omitempty"`
	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`
	LyricsDir         string   `json:"lyrics_dir,omitempty"`

	LyricsTranslationLanguage string `json:"lyrics_translation_language,omitempty"`
}

type featureFlags struct {
	AlbumPrefetch     bool
	LyricsAutoUpgrade bool

	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string
	LyricsDir         string

	LyricsTranslationLanguage string
}

var (
	featuresMu sync.RWMutex
	features   featureFlags
)

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
		AlbumPrefetch:     boolOr(f.AlbumPrefetch, true),
		LyricsAutoUpgrade: boolOr(f.LyricsAutoUpgrade, true),
		LyricsSources: resolveLyricsSources(
			f.LyricsSources,
			f.AMLLLyrics,
			f.LyricFindLyrics,
			f.KuwoLyrics,
			f.MiguLyrics,
			f.DeezerLyrics,
		),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage),
	}
}

func resolveLyricsSources(list []string, amllSeen, lyricFindSeen, kuwoSeen, miguSeen, deezerSeen *bool) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{
			lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
			lyricSourceMusixmatch: true, lyricSourceLRCLIB: true,
			lyricSourceAMLL: true, lyricSourceLyricFind: true, lyricSourceKuwo: true,
			lyricSourceMigu: true, lyricSourceDeezer: true,
		}
	}
	m := make(map[string]bool, len(list)+5)
	for _, source := range list {
		m[source] = true
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
	for key, value := range features.LyricsSources {
		out[key] = value
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
	for key, value := range m {
		out[key] = value
	}
	features.LyricsSources = out
}

func enabledLyricSourceNames() []string {
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	var out []string
	for _, source := range features.LyricsSourceOrder {
		if features.LyricsSources[source] {
			out = append(out, source)
		}
	}
	return out
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
	return append([]string(nil), order...)
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
	return strings.ToLower(s)
}
