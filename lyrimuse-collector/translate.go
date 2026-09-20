package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

const (

	translateMaxChunkChars = 460

	translateMaxChunks = 12

	translateSameLangSentinel = "PLEASE SELECT TWO DISTINCT LANGUAGES"

	translateQuotaSentinel = "ALL AVAILABLE FREE TRANSLATIONS"
)

var lrcLinePattern = regexp.MustCompile(`^\s*(\[\d+:\d+(?:[.:]\d+)?\])\s*(.*)$`)

type lrcLine struct {
	tag  string
	text string
}

func parseLRCLines(lrc string) []lrcLine {
	var out []lrcLine
	for _, raw := range strings.Split(lrc, "\n") {
		m := lrcLinePattern.FindStringSubmatch(raw)
		if m == nil {
			continue
		}
		if text := strings.TrimSpace(m[2]); text != "" {
			out = append(out, lrcLine{tag: m[1], text: text})
		}
	}
	return out
}

func chunkForTranslation(texts []string) [][]string {
	var chunks [][]string
	var cur []string
	curLen := 0
	for _, t := range texts {
		n := len(t) + 1
		if len(cur) > 0 && curLen+n > translateMaxChunkChars {
			chunks = append(chunks, cur)
			cur, curLen = nil, 0
		}
		cur = append(cur, t)
		curLen += n
	}
	if len(cur) > 0 {
		chunks = append(chunks, cur)
	}
	return chunks
}

func looksChinese(text string) bool {
	var han, letters int
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case unicode.IsLetter(r):
			letters++
		}
	}

	return han > 0 && han >= letters
}

func translationUsable(e enrichEntry, target string) bool {
	if e.LyricsTr == "" {
		return false
	}

	lang := e.LyricsTrLang
	if lang != "" && !strings.HasPrefix(strings.ToLower(lang), "zh") && looksChinese(e.LyricsTr) {
		lang = ""
	}
	if lang != "" {
		return myMemoryLangCode(lang) == target
	}

	if strings.HasPrefix(strings.ToLower(target), "zh") {

		return looksChinese(e.LyricsTr)
	}

	return !looksChinese(e.LyricsTr)
}

type translationResult struct {
	lrc          string
	quotaReached bool
}

var translateBaseURL string

func machineTranslateLRC(ctx context.Context, hc *http.Client, lyrics, target string) (translationResult, error) {
	return machineTranslateLRCWithBase(ctx, hc, translateBaseURL, lyrics, target)
}

type lyricScript int

const (
	scriptNone lyricScript = iota
	scriptLatin
	scriptHan
	scriptKana
	scriptHangul
	scriptCyrillic
	scriptArabic
	scriptThai
)

var scriptOrder = []lyricScript{
	scriptKana, scriptHangul, scriptHan, scriptCyrillic, scriptArabic, scriptThai, scriptLatin,
}

func dominantScript(s string) lyricScript {
	counts := map[lyricScript]int{}
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r):
			counts[scriptKana]++
		case unicode.Is(unicode.Han, r):
			counts[scriptHan]++
		case unicode.Is(unicode.Hangul, r):
			counts[scriptHangul]++
		case unicode.Is(unicode.Cyrillic, r):
			counts[scriptCyrillic]++
		case unicode.Is(unicode.Arabic, r):
			counts[scriptArabic]++
		case unicode.Is(unicode.Thai, r):
			counts[scriptThai]++
		case unicode.IsLetter(r):
			counts[scriptLatin]++
		}
	}
	if counts[scriptKana] > 0 {
		return scriptKana
	}
	best, bestN := scriptNone, 0
	for _, k := range scriptOrder {
		if counts[k] > bestN {
			best, bestN = k, counts[k]
		}
	}
	return best
}

func targetScripts(target string) []lyricScript {
	t := strings.ToLower(strings.TrimSpace(target))
	switch {
	case strings.HasPrefix(t, "zh"):
		return []lyricScript{scriptHan}
	case strings.HasPrefix(t, "ja"):
		return []lyricScript{scriptKana, scriptHan}
	case strings.HasPrefix(t, "ko"):
		return []lyricScript{scriptHangul}
	case strings.HasPrefix(t, "ru"), strings.HasPrefix(t, "uk"):
		return []lyricScript{scriptCyrillic}
	case strings.HasPrefix(t, "ar"):
		return []lyricScript{scriptArabic}
	case strings.HasPrefix(t, "th"):
		return []lyricScript{scriptThai}
	default:
		return []lyricScript{scriptLatin}
	}
}

func lineNeedsTranslation(text, target string) bool {
	s := dominantScript(text)
	if s == scriptNone {
		return false
	}
	for _, ts := range targetScripts(target) {
		if s == ts {
			return false
		}
	}
	return true
}

func anyLineNeedsTranslation(lyrics, target string) bool {
	for _, l := range parseLRCLines(lyrics) {
		if lineNeedsTranslation(l.text, target) {
			return true
		}
	}
	return false
}

func machineTranslateLRCWithBase(ctx context.Context, hc *http.Client, baseURL, lyrics, target string) (translationResult, error) {
	if lyrics == "" || target == "" {
		return translationResult{}, nil
	}
	lines := parseLRCLines(lyrics)
	if len(lines) == 0 {
		return translationResult{}, nil
	}

	speakers := lyricSpeakerLabels(lyrics)
	seen := map[string]int{}
	var uniqueTexts []string
	var occurrences [][]int
	totalAttempted := 0
	for i, l := range lines {
		if isCreditLineWithSpeakers(strings.TrimSpace(l.text), speakers) {
			continue
		}
		if !lineNeedsTranslation(l.text, target) {
			continue
		}
		totalAttempted++
		if k, ok := seen[l.text]; ok {
			occurrences[k] = append(occurrences[k], i)
			continue
		}
		seen[l.text] = len(uniqueTexts)
		uniqueTexts = append(uniqueTexts, l.text)
		occurrences = append(occurrences, []int{i})
	}
	if len(uniqueTexts) == 0 {
		return translationResult{}, nil
	}

	scatter := func(out []string) []string {
		full := make([]string, len(lines))
		for k, occ := range occurrences {
			if k >= len(out) {
				break
			}
			for _, i := range occ {
				full[i] = out[k]
			}
		}
		return full
	}

	if out, err := onDeviceTranslate(ctx, appleLangCode(target), uniqueTexts); err == nil {
		return assembleTranslationLRC(lines, scatter(out), totalAttempted), nil
	} else if !errors.Is(err, errOnDeviceUnavailable) {
		log.Printf("translate: on-device failed, falling back to network: %v", err)
	}

	chunks := chunkForTranslation(uniqueTexts)
	if len(chunks) > translateMaxChunks {
		return translationResult{}, fmt.Errorf("lyrics too long: %d chunks", len(chunks))
	}

	translated := make([]string, 0, len(uniqueTexts))
	for _, chunk := range chunks {
		out, quota, err := translateChunk(ctx, hc, baseURL, chunk, target)
		if quota {
			return translationResult{quotaReached: true}, nil
		}
		if err != nil {
			return translationResult{}, err
		}

		if len(out) != len(chunk) {
			out = chunk
		}
		translated = append(translated, out...)
	}

	return assembleTranslationLRC(lines, scatter(translated), totalAttempted), nil
}

func assembleTranslationLRC(lines []lrcLine, translated []string, attempted int) translationResult {
	var b strings.Builder
	written := 0
	for i, l := range lines {
		if i >= len(translated) {
			break
		}
		t := strings.TrimSpace(translated[i])
		if t == "" || t == l.text {
			continue
		}
		b.WriteString(l.tag)
		b.WriteString(t)
		b.WriteString("\n")
		written++
	}

	if attempted <= 0 || written*3 < attempted {
		return translationResult{}
	}
	return translationResult{lrc: strings.TrimRight(b.String(), "\n")}
}

func randomTranslateEmail() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {

		return fmt.Sprintf("lyrimuse-%d@example.com", time.Now().UnixNano())
	}
	return "lyrimuse-" + hex.EncodeToString(b[:]) + "@example.com"
}

func translateChunk(ctx context.Context, hc *http.Client, baseURL string, lines []string, target string) ([]string, bool, error) {
	q := neturl.Values{}
	q.Set("q", strings.Join(lines, "\n"))

	q.Set("langpair", "autodetect|"+target)
	q.Set("de", randomTranslateEmail())
	if baseURL == "" {
		baseURL = "https://api.mymemory.translated.net/get"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return nil, false, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(hc, req)
	if err != nil {
		return nil, false, fmt.Errorf("translate: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		ResponseData struct {
			TranslatedText string `json:"translatedText"`
		} `json:"responseData"`
		ResponseStatus  json.RawMessage `json:"responseStatus"`
		ResponseDetails string          `json:"responseDetails"`
		QuotaFinished   bool            `json:"quotaFinished"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, false, fmt.Errorf("decode translate response: %w", err)
	}
	if body.QuotaFinished ||
		resp.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(strings.ToUpper(body.ResponseDetails), translateQuotaSentinel) {
		return nil, true, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, false, fmt.Errorf("translate status %d: %s", resp.StatusCode, body.ResponseDetails)
	}
	text := body.ResponseData.TranslatedText
	if text == "" || strings.Contains(strings.ToUpper(text), translateSameLangSentinel) {
		return nil, false, fmt.Errorf("no usable translation: %q", body.ResponseDetails)
	}
	return strings.Split(text, "\n"), false, nil
}

var translateClient = &http.Client{Timeout: 15 * time.Second}

const (
	translationBackfillMaxAttempts = 3
	translationBackfillInterval    = 6 * time.Hour
)

func invalidateStaleTranslations() {
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		return
	}
	enrichMu.Lock()
	cleared := 0
	for key, e := range enrichCache {
		if e.LyricsTr == "" || e.LyricsTrSource != "machine" {
			continue
		}

		if e.LyricsTrLang == "" || myMemoryLangCode(e.LyricsTrLang) == target {
			continue
		}
		e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = "", "", ""

		e.TranslationRetryCount, e.TranslationTS, e.TranslationLang = 0, 0, ""
		enrichCache[key] = e
		cleared++
	}
	if cleared > 0 {

		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("cleared %d machine translation(s) whose language no longer matches %q", cleared, target)

		saveEnrichCache()
	}
}

func needsTranslationBackfill(e enrichEntry) bool {
	if !features.LyricsMachineTranslation {
		return false
	}
	if e.Lyrics == "" {
		return false
	}
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		return false
	}
	if translationUsable(e, target) {
		return false
	}

	sameTarget := e.TranslationLang == "" || e.TranslationLang == target
	if sameTarget && e.TranslationRetryCount >= translationBackfillMaxAttempts {
		return false
	}

	if !anyLineNeedsTranslation(e.Lyrics, target) {
		return false
	}
	if sameTarget && e.TranslationTS > 0 &&
		time.Now().Unix()-e.TranslationTS < int64(translationBackfillInterval/time.Second) {
		return false
	}
	return true
}

func myMemoryLangCode(iso string) string {
	switch strings.ToLower(strings.TrimSpace(iso)) {
	case "":
		return ""
	case "zh", "zh-hans", "zh-cn":
		return "zh-CN"
	case "zh-hant", "zh-tw":
		return "zh-TW"
	default:
		return strings.ToLower(iso)
	}
}

func backfillTranslation(ctx context.Context, key string) {
	if ctx == nil {
		ctx = context.Background()
	}
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	enrichMu.Lock()
	lyrics := enrichCache[key].Lyrics
	enrichMu.Unlock()
	if lyrics == "" {
		return
	}

	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	res, err := machineTranslateLRC(ctx, translateClient, lyrics, target)

	enrichMu.Lock()

	lyricsChanged := false
	defer func() {
		enrichMu.Unlock()
		saveEnrichCache()
		if !lyricsChanged {
			return
		}
		exportLyricsFiles()

		if enrichNotify != nil {
			select {
			case enrichNotify <- struct{}{}:
			default:
			}
		}
	}()
	e, ok := enrichCache[key]
	if !ok {

		return
	}

	if translationUsable(e, target) {
		return
	}
	e.TranslationTS = time.Now().Unix()
	if e.TranslationLang != target {

		e.TranslationRetryCount = 0
		e.TranslationLang = target
	}
	switch {
	case res.quotaReached:

		log.Printf("translate: %s deferred, daily quota reached", key)
	case err != nil:
		e.TranslationRetryCount++
		log.Printf("translate: %s failed: %v", key, err)
	case res.lrc == "":
		e.TranslationRetryCount++
		log.Printf("translate: %s produced nothing usable (already target language, or too few lines translated)", key)
	default:
		e.LyricsTr = res.lrc
		e.LyricsTrSource = lyricsTrSourceMachine
		e.LyricsTrLang = target
		lyricsChanged = true
		log.Printf("translate: %s got a machine translation (%d lines)", key, strings.Count(res.lrc, "\n")+1)
	}
	enrichCache[key] = e
	enrichDirty = true
}

const lyricsTrSourceMachine = "machine"

var errOnDeviceUnavailable = errors.New("on-device translation unavailable")

func onDeviceTranslate(ctx context.Context, target string, lines []string) ([]string, error) {
	if target == "" || len(lines) == 0 {
		return nil, errOnDeviceUnavailable
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, errOnDeviceUnavailable
	}
	bin := filepath.Join(filepath.Dir(exe), "lyrics-translate")
	if _, err := os.Stat(bin); err != nil {
		return nil, errOnDeviceUnavailable
	}
	payload, err := json.Marshal(struct {
		Target string   `json:"target"`
		Lines  []string `json:"lines"`
	}{Target: target, Lines: lines})
	if err != nil {
		return nil, fmt.Errorf("marshal translate request: %w", err)
	}

	cmd := exec.CommandContext(ctx, bin)
	cmd.Stdin = bytes.NewReader(payload)
	out, err := cmd.Output()

	var res struct {
		OK     bool     `json:"ok"`
		Source string   `json:"source"`
		Lines  []string `json:"lines"`
		Reason string   `json:"reason"`
	}
	if jsonErr := json.Unmarshal(out, &res); jsonErr != nil {
		if err != nil {
			return nil, fmt.Errorf("run lyrics-translate: %w", err)
		}
		return nil, fmt.Errorf("parse lyrics-translate output: %w", jsonErr)
	}
	if !res.OK {
		switch res.Reason {
		case "same-language", "needs-macos-26", "no-translation-framework", "undetected-source":
			return nil, errOnDeviceUnavailable
		case "supported", "notSupported", "unsupported":

			log.Printf("translate: on-device pack for %s not installed (%s), using network fallback",
				res.Source, res.Reason)
			return nil, errOnDeviceUnavailable
		default:
			return nil, fmt.Errorf("lyrics-translate: %s", res.Reason)
		}
	}
	if len(res.Lines) != len(lines) {
		return nil, fmt.Errorf("lyrics-translate returned %d lines for %d", len(res.Lines), len(lines))
	}
	return res.Lines, nil
}

func appleLangCode(iso string) string {
	switch strings.ToLower(strings.TrimSpace(iso)) {
	case "":
		return ""
	case "zh", "zh-cn", "zh-hans":
		return "zh-Hans"
	case "zh-tw", "zh-hant":
		return "zh-Hant"
	default:
		return strings.ToLower(iso)
	}
}
