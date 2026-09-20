package main

import (
	"context"
	_ "image/jpeg"
	_ "image/png"
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

var lrcTimestampRe = regexp.MustCompile(`\[\d{1,2}:\d{2}[.:]\d{1,3}\]`)
var lrcTimestampCaptureRe = regexp.MustCompile(`\[(\d{1,2}):(\d{2})[.:](\d{1,3})\]`)

func isTimedLRC(s string) bool {
	if s == "" || len(s) >= 20000 {
		return false
	}
	lines := strings.Split(s, "\n")
	timedLines := 0
	for _, l := range lines {
		if lrcTimestampRe.MatchString(l) {
			timedLines++
		}
	}
	return timedLines >= 3 && timedLines*2 >= len(lines)
}

func cjkRatio(s string) float64 {
	stripped := lrcTimestampRe.ReplaceAllString(s, "")
	total, cjk := 0, 0
	for _, r := range stripped {
		if unicode.IsSpace(r) {
			continue
		}
		total++
		if unicode.Is(unicode.Han, r) {
			cjk++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(cjk) / float64(total)
}

func isProbablyWrongLanguageLyrics(localArtist, localTitle, candidateArtist, lyrics string) bool {
	if cjkRatio(localArtist) > 0 || cjkRatio(localTitle) > 0 {
		return false
	}
	if cjkRatio(candidateArtist) > 0 || cjkRatio(knownArtistAlias(localArtist)) > 0 ||
		cjkRatio(resolvedArtistCJKHint(localArtist)) > 0 {
		return false
	}
	return cjkRatio(lyrics) > 0.5
}

var creditLineRe = regexp.MustCompile(`(?i)^(作词|作曲|编曲|制作人|演唱|混音|录音|lyrics by|composed by|written by|produced by|arranged by)\s*[:：]`)

var genericHanCreditLineRe = regexp.MustCompile(`^\p{Han}{1,8}[:：]`)

func isCreditLine(text string) bool {
	return creditLineRe.MatchString(text) || genericHanCreditLineRe.MatchString(text)
}

const neteaseInstrumentalPlaceholderMarker = "纯音乐"

func isCreditOnlyLRC(lrc string) bool {
	if strings.Contains(lrc, neteaseInstrumentalPlaceholderMarker) {
		return true
	}

	speakers := lyricSpeakerLabels(lrc)
	nonCredit := 0
	for _, l := range splitLyricLines(lrc) {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, ""))
		if text == "" || isCreditLineWithSpeakers(text, speakers) {
			continue
		}
		nonCredit++
	}
	return nonCredit < 3
}

func lastLRCTimestampSecs(lrc string) (float64, bool) {
	lines := strings.Split(lrc, "\n")
	speakers := lyricSpeakerLabels(lrc)
	for i := len(lines) - 1; i >= 0; i-- {
		matches := lrcTimestampCaptureRe.FindAllStringSubmatch(lines[i], -1)
		if len(matches) == 0 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(lines[i], ""))
		if text == "" || isCreditLineWithSpeakers(text, speakers) {
			continue
		}
		m := matches[len(matches)-1]
		mm, _ := strconv.Atoi(m[1])
		ss, _ := strconv.Atoi(m[2])
		frac, _ := strconv.Atoi(m[3])
		fracSecs := float64(frac) / math.Pow(10, float64(len(m[3])))
		return float64(mm*60+ss) + fracSecs, true
	}
	return 0, false
}

type lyricCandidate struct {
	source        string
	lyrics        string
	wordTimingYRC string
	hasWordTiming bool

	timelineRemap map[int]int

	hasUsableTranslation  bool
	hasUsableRomanization bool

	sourceReportedDurationSecs float64

	title, artist, album, cover string

	language string

	languageVersionMismatch bool
	languageVersionAgrees   bool

	plainTextOnly bool
}

const (
	songLanguageCantonese = "yue"
	songLanguageMandarin  = "cmn"
)

const lyricEndingCorroborationToleranceSecs = 5.0

const durationFitTolerance = 0.25

func durationFits(lastSecs, durationSecs float64) bool {
	if durationSecs <= 0 {
		return false
	}

	if lastSecs > durationSecs+lyricOvershootToleranceSecs {
		return false
	}
	return math.Abs(lastSecs-durationSecs)/durationSecs <= durationFitTolerance
}

func corroboratedEndings(candidates []lyricCandidate, durationSecs float64) map[string]bool {
	type ending struct {
		source string
		secs   float64
	}
	var endings []ending
	for _, c := range candidates {
		if secs, ok := lastLRCTimestampSecs(c.lyrics); ok {
			endings = append(endings, ending{c.source, secs})
		}
	}
	if durationSecs > 0 {
		for _, e := range endings {
			if durationFits(e.secs, durationSecs) {
				return map[string]bool{}
			}
		}
	}
	corroborated := map[string]bool{}
	for i := range endings {
		for j := range endings {
			if i == j || endings[i].source == endings[j].source {
				continue
			}
			if math.Abs(endings[i].secs-endings[j].secs) <= lyricEndingCorroborationToleranceSecs {
				corroborated[endings[i].source] = true
			}
		}
	}
	return corroborated
}

func sourceDurationFits(localSecs, sourceSecs float64) bool {
	if localSecs <= 0 || sourceSecs <= 0 {
		return true
	}
	larger := math.Max(localSecs, sourceSecs)
	return math.Abs(localSecs-sourceSecs)/larger <= sourceDurationMismatchTolerance
}

const lyricOvershootToleranceSecs = 5.0

const lyricsScoringVersion = 18

type scoreTerm struct {
	Kind   string `json:"kind"`
	Points int    `json:"points"`
}

const (
	scoreTermDuration     = "duration"
	scoreTermCorroborated = "corroborated"
	scoreTermWordTiming   = "wordTiming"
	scoreTermNativeSource = "nativeSource"
	scoreTermSource       = "source"
	scoreTermLines        = "lines"
	scoreTermVersionTags  = "versionTags"
	scoreTermDurationOff  = "durationOff"

	scoreTermDurationOvershoot = "durationOvershoot"
	scoreTermAlbum             = "album"
	scoreTermTitleMatch        = "titleMatch"
	scoreTermConsensus         = "consensus"
	scoreTermTranslation       = "translation"
	scoreTermRoma              = "romanization"

	scoreTermSourceDurationOff = "sourceDurationOff"

	scoreTermWordTimingOverride = "wordTimingOverride"

	scoreTermLiveAlbumConflict = "liveAlbumConflict"
)

func lyricScoreTermKinds() []string {
	return []string{
		scoreTermDuration, scoreTermCorroborated, scoreTermWordTiming,
		scoreTermNativeSource, scoreTermLines, scoreTermVersionTags,
		scoreTermDurationOff, scoreTermDurationOvershoot, scoreTermAlbum,
		scoreTermTitleMatch, scoreTermConsensus, scoreTermTranslation,
		scoreTermRoma, scoreTermSourceDurationOff, scoreTermWordTimingOverride,
		scoreTermLiveAlbumConflict,
	}
}

const durationMismatchPenalty = 500

const (
	sourceDurationMismatchPenalty   = 400
	sourceDurationMismatchTolerance = 0.12
)

const (
	scoreRejectNotTimed        = "rejectNotTimed"
	scoreRejectWrongLanguage   = "rejectWrongLanguage"
	scoreRejectCreditOnly      = "rejectCreditOnly"
	scoreRejectNoLastTimestamp = "rejectNoLastTimestamp"

	scoreRejectDurationMismatch = "rejectDurationMismatch"

	scoreRejectPlainTextOnly = "rejectPlainTextOnly"
)

var (
	nativeLyricSourcesMu sync.RWMutex
	nativeLyricSources   map[string]bool
)

func setNativeLyricSourcesForPlayer(bundleID string) {
	src := playerNativeLyricSource(playerForBundleID(bundleID))
	nativeLyricSourcesMu.Lock()
	defer nativeLyricSourcesMu.Unlock()
	if src == "" {
		nativeLyricSources = nil
		return
	}
	if len(nativeLyricSources) == 1 && nativeLyricSources[src] {
		return
	}
	nativeLyricSources = map[string]bool{src: true}
}

func isNativeLyricSource(src string) bool {
	nativeLyricSourcesMu.RLock()
	defer nativeLyricSourcesMu.RUnlock()
	return nativeLyricSources[src]
}

func hasNativeLyricSource() bool {
	nativeLyricSourcesMu.RLock()
	defer nativeLyricSourcesMu.RUnlock()
	return len(nativeLyricSources) > 0
}

func playerForBundleID(bundleID string) string {
	switch bundleID {
	case appleMusicBundleID:
		return playerAppleMusic
	case qqMusicBundleID:
		return playerQQMusic
	case neteaseMusicBundleID:
		return playerNetease
	case spotifyBundleID:
		return playerSpotify
	case kugouMusicBundleID:
		return playerKugou
	default:
		return ""
	}
}

func playerNativeLyricSource(player string) string {
	switch player {
	case playerQQMusic:
		return "qq"
	case playerNetease:
		return "netease"
	case playerKugou:

		return "kugou"
	default:
		return ""
	}
}

func scoreLyricCandidate(
	localArtist, localTitle, localAlbum string, durationSecs float64,
	c lyricCandidate, corroborated bool, consensusPeers int,
) int {
	score, _ := scoreLyricCandidateDetailed(localArtist, localTitle, localAlbum, durationSecs, c, corroborated, consensusPeers)
	return score
}

func scoreLyricCandidateDetailed(
	localArtist, localTitle, localAlbum string, durationSecs float64,
	c lyricCandidate, corroborated bool, consensusPeers int,
) (int, []scoreTerm) {
	reject := func(kind string) (int, []scoreTerm) {
		return -1, []scoreTerm{{Kind: kind}}
	}

	if c.plainTextOnly {
		return reject(scoreRejectPlainTextOnly)
	}
	if !isTimedLRC(c.lyrics) {
		return reject(scoreRejectNotTimed)
	}

	if consensusPeers < 1 && isProbablyWrongLanguageLyrics(localArtist, localTitle, c.artist, c.lyrics) {
		return reject(scoreRejectWrongLanguage)
	}
	if isCreditOnlyLRC(c.lyrics) {
		return reject(scoreRejectCreditOnly)
	}
	score := 0
	var terms []scoreTerm
	add := func(kind string, points int) {
		if points == 0 {
			return
		}
		score += points
		terms = append(terms, scoreTerm{Kind: kind, Points: points})
	}
	if durationSecs > 0 {
		last, ok := lastLRCTimestampSecs(c.lyrics)
		if !ok {
			return reject(scoreRejectNoLastTimestamp)
		}
		ratio := math.Abs(last-durationSecs) / durationSecs
		switch {
		case durationFits(last, durationSecs):

			add(scoreTermDuration, 100+int(200*(1-ratio/durationFitTolerance)))
		case last > durationSecs+lyricOvershootToleranceSecs:

			add(scoreTermDurationOvershoot, -700)
		case corroborated:

			add(scoreTermCorroborated, 100)
		default:

			add(scoreTermDurationOff, -durationMismatchPenalty)
		}
	}

	if durationSecs > 0 && c.sourceReportedDurationSecs > 0 {
		larger := math.Max(c.sourceReportedDurationSecs, durationSecs)
		if math.Abs(c.sourceReportedDurationSecs-durationSecs)/larger > sourceDurationMismatchTolerance {
			add(scoreTermSourceDurationOff, -sourceDurationMismatchPenalty)
		}
	}
	if c.hasWordTiming {
		add(scoreTermWordTiming, 400)
	}
	if isNativeLyricSource(c.source) {

		add(scoreTermNativeSource, 250)
	}

	lines := len(strings.Split(c.lyrics, "\n"))
	if lines > 200 {
		lines = 200
	}
	add(scoreTermLines, lines)

	switch {
	case c.languageVersionMismatch:
		add(scoreTermVersionTags, -versionMismatchPenalty)
	case versionTagsMismatchIgnoringLanguage(localTitle, localAlbum, c.title, c.album, c.languageVersionAgrees) &&
		!sameRecordingDespiteVersionTagsIgnoringLanguage(localTitle, localAlbum, durationSecs,
			c.title, c.album, c.sourceReportedDurationSecs, c.languageVersionAgrees):
		add(scoreTermVersionTags, -versionMismatchPenalty)
	}

	if liveAlbumIdentityConflict(localArtist, localTitle, localAlbum, c.title, c.album) {
		add(scoreTermLiveAlbumConflict, -liveAlbumConflictPenalty)
	}

	if strings.TrimSpace(localAlbum) != "" && strings.TrimSpace(c.album) != "" {
		switch s := albumScore(c.album, localAlbum); {
		case s >= 200:
			add(scoreTermAlbum, 150)
		case s >= 100:
			add(scoreTermAlbum, 75)
		case s >= 1:
			add(scoreTermAlbum, 40)
		}
	}

	if p := titleMatchTierPointsIgnoringLanguage(c.title, localTitle, c.languageVersionAgrees); p > 0 {
		add(scoreTermTitleMatch, p)
	}

	switch {
	case consensusPeers >= 2:
		add(scoreTermConsensus, 250)
	case consensusPeers == 1:
		add(scoreTermConsensus, 150)
	}

	if c.hasUsableTranslation {
		add(scoreTermTranslation, 50)
	}
	if c.hasUsableRomanization {
		add(scoreTermRoma, 30)
	}

	if score < 1 {
		score = 1
	}
	return score, terms
}

func scoreTermPoints(terms []scoreTerm, kind string) int {
	for _, t := range terms {
		if t.Kind == kind {
			return t.Points
		}
	}
	return 0
}

func applyWordTimingTitleOverride(results []scoredLyricCandidateResult) {
	winnerIdx := -1
	for i := range results {
		if results[i].Score < 0 {
			continue
		}
		if winnerIdx == -1 || results[i].Score > results[winnerIdx].Score {
			winnerIdx = i
		}
	}
	if winnerIdx == -1 {
		return
	}
	winner := &results[winnerIdx]
	wtPoints := scoreTermPoints(winner.ScoreTerms, scoreTermWordTiming)
	if wtPoints <= 0 {
		return
	}
	scoreWithoutWT := winner.Score - wtPoints

	runnerUpIdx := -1
	for i := range results {
		if i == winnerIdx || results[i].Score < 0 || results[i].Score <= scoreWithoutWT {
			continue
		}
		if runnerUpIdx == -1 || results[i].Score > results[runnerUpIdx].Score {
			runnerUpIdx = i
		}
	}
	if runnerUpIdx == -1 {
		return
	}
	runnerUp := &results[runnerUpIdx]
	if scoreTermPoints(runnerUp.ScoreTerms, scoreTermTitleMatch) <= scoreTermPoints(winner.ScoreTerms, scoreTermTitleMatch) {
		return
	}

	winner.Score -= wtPoints
	if winner.Score < 1 {
		winner.Score = 1
	}
	winner.ScoreTerms = append(winner.ScoreTerms, scoreTerm{Kind: scoreTermWordTimingOverride, Points: -wtPoints})
}

func normLoose(s string) string {
	var b strings.Builder

	for _, r := range foldDiacritics(strings.ToLower(toSimplified(s))) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func looseContains(a, b string) bool {
	na, nb := normLoose(a), normLoose(b)
	if na == "" || nb == "" {
		return false
	}
	return na == nb || strings.Contains(na, nb) || strings.Contains(nb, na)
}

func artistCreditParts(s string) []string {
	var parts []string
	for _, p := range strings.FieldsFunc(strings.TrimSpace(strings.ToLower(toSimplified(normalizeArtistCreditHanAnd(s)))), isArtistCreditSep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

func normalizeArtistCreditHanAnd(s string) string {
	runes := []rune(s)
	hasHanAnd := false
	for _, r := range runes {
		if r == '和' {
			hasHanAnd = true
			break
		}
	}
	if !hasHanAnd {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for i, r := range runes {
		if r == '和' && i > 0 && i < len(runes)-1 &&
			((isASCIILetter(runes[i-1]) && isASCIILetter(runes[i+1])) ||
				(hanRunLenBefore(runes, i) >= 2 && hanRunLenAfter(runes, i) >= 2)) {
			b.WriteByte('&')
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func hanRunLenBefore(runes []rune, i int) int {
	n := 0
	for j := i - 1; j >= 0; j-- {
		r := runes[j]
		if r == '和' || isArtistCreditSep(r) || !unicode.Is(unicode.Han, r) {
			break
		}
		n++
	}
	return n
}

func hanRunLenAfter(runes []rune, i int) int {
	n := 0
	for j := i + 1; j < len(runes); j++ {
		r := runes[j]
		if r == '和' || isArtistCreditSep(r) || !unicode.Is(unicode.Han, r) {
			break
		}
		n++
	}
	return n
}

func isASCIILetter(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

func isArtistCreditSep(r rune) bool {
	return r == '/' || r == '、' || r == '&' || r == ',' || r == '，'
}

func isArtistCreditPrimarySep(r rune) bool {
	return r == '、' || r == '&' || r == ',' || r == '，'
}

func firstCreditedField(s string, sep func(rune) bool) (string, bool) {
	var parts []string
	for _, p := range strings.FieldsFunc(s, sep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) >= 2 {
		return parts[0], true
	}
	return "", false
}

func slashHeadPlausible(head string) bool {
	if head == "" {
		return false
	}
	hasHan := false
	for _, r := range head {
		if r >= 0x4E00 && r <= 0x9FFF {
			hasHan = true
			break
		}
	}
	min := 3
	if hasHan {
		min = 2
	}
	return utf8.RuneCountInString(head) >= min
}

func firstCreditedArtist(s string) string {
	trimmed := strings.TrimSpace(s)

	normalized := normalizeArtistCreditHanAnd(trimmed)
	if head, ok := firstCreditedField(normalized, isArtistCreditPrimarySep); ok {
		return head
	}
	if head, ok := firstSlashCredit(normalized); ok {
		return head
	}
	return trimmed
}

func firstSlashCredit(s string) (string, bool) {
	var parts []string
	for _, p := range strings.FieldsFunc(s, func(r rune) bool { return r == '/' }) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) < 2 {
		return "", false
	}
	head := parts[0]
	for i := 1; i < len(parts); i++ {
		if slashHeadPlausible(head) {
			return head, true
		}
		head += "/" + parts[i]
	}
	return "", false
}

func artistMatches(a, b string) bool {
	na, nb := strings.TrimSpace(strings.ToLower(toSimplified(a))), strings.TrimSpace(strings.ToLower(toSimplified(b)))
	if na == "" || nb == "" {
		return false
	}
	if na == nb {
		return true
	}
	if pa := artistCreditParts(na); len(pa) >= 2 {
		for _, part := range pa {
			if part == nb {
				return true
			}
		}

		if artistCreditRunMatches(na, nb) {
			return true
		}
	}
	if pb := artistCreditParts(nb); len(pb) >= 2 {
		for _, part := range pb {
			if part == na {
				return true
			}
		}
		if artistCreditRunMatches(nb, na) {
			return true
		}
	}

	if sa := stripParens(na); sa != na && sa != "" && artistMatches(sa, nb) {
		return true
	}
	if sb := stripParens(nb); sb != nb && sb != "" && artistMatches(na, sb) {
		return true
	}
	return false
}

func artistCreditRunMatches(hay, needle string) bool {
	if hay == "" || needle == "" || len(needle) > len(hay) {
		return false
	}
	for off := 0; off+len(needle) <= len(hay); {
		i := strings.Index(hay[off:], needle)
		if i < 0 {
			return false
		}
		i += off
		if artistCreditBoundaryBefore(hay[:i]) && artistCreditBoundaryAfter(hay[i+len(needle):]) {
			return true
		}
		off = i + 1
	}
	return false
}

func artistCreditBoundaryBefore(s string) bool {
	s = strings.TrimRight(s, " \t")
	if s == "" {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(s)
	return isArtistCreditSep(r)
}

func artistCreditBoundaryAfter(s string) bool {
	s = strings.TrimLeft(s, " \t")
	if s == "" {
		return true
	}
	r, _ := utf8.DecodeRuneInString(s)
	return isArtistCreditSep(r)
}

func lyricSourceArtistMatches(candidate, query string) bool {
	if artistMatches(candidate, query) {
		return true
	}
	pc, pq := artistCreditParts(candidate), artistCreditParts(query)
	if len(pc) < 2 || len(pq) < 2 {
		return false
	}
	for _, c := range pc {
		for _, q := range pq {
			if c == q {
				return true
			}
		}
	}
	return false
}

const (

	lyricRecordingTriangleDurationTolerance = 0.01

	lyricRecordingTriangleAlbumWidthRatio = 0.6
)

func lyricRecordingTriangleMatches(candTitle, candAlbum string, candDurationSecs float64,
	localTitle, localAlbum string, localDurationSecs float64) bool {

	nct, nlt := normLoose(candTitle), normLoose(localTitle)
	if nct == "" || nlt == "" || nct != nlt {
		return false
	}

	if candDurationSecs <= 0 || localDurationSecs <= 0 {
		return false
	}
	if math.Abs(candDurationSecs-localDurationSecs)/localDurationSecs > lyricRecordingTriangleDurationTolerance {
		return false
	}

	if strings.TrimSpace(candAlbum) == "" || strings.TrimSpace(localAlbum) == "" {
		return false
	}
	switch sc := albumScore(candAlbum, localAlbum); {
	case sc >= 200:
	case sc >= 100:

		nca, nla := utf8.RuneCountInString(normLoose(candAlbum)), utf8.RuneCountInString(normLoose(localAlbum))
		lo, hi := min(nca, nla), max(nca, nla)
		if hi == 0 || float64(lo) < lyricRecordingTriangleAlbumWidthRatio*float64(hi) {
			return false
		}
	default:
		return false
	}

	return !versionTagsMismatch(localTitle, localAlbum, candTitle, candAlbum)
}

var featCreditSepRe = regexp.MustCompile(`(?i)\s*[(（]?\s*\b(?:feat\.|feat\b|ft\.|ft\b|featuring\b)`)

func isCJKScriptRune(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
		unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r)
}

func cjkSpaceStripped(s string) string {
	runes := []rune(s)
	out := make([]rune, 0, len(runes))
	dropped := false
	for i, r := range runes {
		if !unicode.IsSpace(r) {
			out = append(out, r)
			continue
		}

		var prev, next rune
		for j := i - 1; j >= 0; j-- {
			if !unicode.IsSpace(runes[j]) {
				prev = runes[j]
				break
			}
		}
		for j := i + 1; j < len(runes); j++ {
			if !unicode.IsSpace(runes[j]) {
				next = runes[j]
				break
			}
		}
		if isCJKScriptRune(prev) && isCJKScriptRune(next) {
			dropped = true
			continue
		}
		out = append(out, r)
	}
	if !dropped {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func lyricPrimaryQueryArtist(artist string) string {
	trimmed := strings.TrimSpace(artist)
	if trimmed == "" {
		return ""
	}
	base := trimmed
	if loc := featCreditSepRe.FindStringIndex(base); loc != nil {
		base = strings.TrimSpace(base[:loc[0]])
	}
	primary := strings.TrimSpace(firstCreditedArtist(base))

	if primary == "" || normLoose(primary) == normLoose(trimmed) {
		return cjkSpaceStripped(trimmed)
	}

	if stripped := cjkSpaceStripped(primary); stripped != "" {
		return stripped
	}
	return primary
}

var artistAliasTable = map[string]string{

	"pei-yu hung": "洪佩瑜",

	"宇多田光": "宇多田ヒカル",

	"wanting": "曲婉婷",

	"utada":        "宇多田ヒカル",
	"hikaru utada": "宇多田ヒカル",

	"lexie liu": "刘柏辛",
}

func hanOnlyPortion(s string) string {
	hasASCII, hasHan := false, false
	for _, r := range s {
		if isASCIILetter(r) {
			hasASCII = true
		}
		if unicode.Is(unicode.Han, r) {
			hasHan = true
		}
	}
	if !hasASCII || !hasHan {
		return ""
	}
	runes := []rune(s)
	bestStart, bestLen := -1, 0
	curStart, curLen := -1, 0
	flush := func() {
		if curLen > bestLen {
			bestStart, bestLen = curStart, curLen
		}
		curLen = 0
	}
	for i, r := range runes {
		if unicode.Is(unicode.Han, r) {
			if curLen == 0 {
				curStart = i
			}
			curLen++
		} else {
			flush()
		}
	}
	flush()
	if bestLen < 2 {
		return ""
	}
	return string(runes[bestStart : bestStart+bestLen])
}

func retryArtistIdentities(ctx context.Context, artist string) []string {
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		k := normLoose(s)
		if seen[k] {
			return
		}
		seen[k] = true
		out = append(out, s)
	}

	add(hanOnlyPortion(artist))

	add(learnedSourceArtistAlias(artist))
	add(canonicalArtistViaMusicBrainz(ctx, artist))

	for _, alt := range musicBrainzArtistAliases(ctx, artist) {
		add(alt)
	}

	add(cachedQQArtistCanonicalName(artist))
	return out
}

func knownArtistAlias(artist string) string {
	return artistAliasTable[strings.ToLower(strings.TrimSpace(artist))]
}

var neteaseImpersonatorRiddenArtists = map[string]bool{
	"周杰伦": true,
	"周杰倫": true,
}

func isNeteaseImpersonatorRidden(artist string) bool {
	return neteaseImpersonatorRiddenArtists[strings.TrimSpace(artist)]
}

func toSimplified(s string) string {
	return toSimplifiedT2S(s)
}

var albumStop = map[string]bool{
	"the": true, "a": true, "an": true, "and": true, "of": true, "in": true, "on": true,
	"at": true, "to": true, "for": true, "with": true, "book": true, "vol": true,
	"volume": true, "disc": true, "cd": true, "edition": true, "deluxe": true,
	"remastered": true, "part": true, "pt": true, "feat": true, "ft": true,
	"i": true, "ii": true, "iii": true, "iv": true,
}

func albumTokens(s string) map[string]bool {
	out := map[string]bool{}
	s = strings.ToLower(s)
	var cur []rune
	const (
		kindNone = iota
		kindDigit
		kindLatin
		kindCJK
	)
	prevKind := kindNone
	flush := func() {
		if len(cur) > 1 {
			t := string(cur)
			if !albumStop[t] {
				out[t] = true
			}
		}
		cur = cur[:0]
	}
	for _, r := range s {
		k := kindNone
		switch {
		case unicode.IsDigit(r):
			k = kindDigit
		case unicode.IsLetter(r):
			if isCJKRune(r) {
				k = kindCJK
			} else {
				k = kindLatin
			}
		}
		if k == kindNone {
			flush()
			prevKind = kindNone
			continue
		}
		if prevKind != kindNone && prevKind != k {
			flush()
		}
		cur = append(cur, r)
		prevKind = k
	}
	flush()
	return out
}

func isCJKRune(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
		unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r)
}

func albumScore(candidate, target string) int {
	if candidate == "" || target == "" {
		return 0
	}

	nc, nt := normLoose(candidate), normLoose(target)
	if nc == nt {
		return 200
	}
	if strings.Contains(nc, nt) || strings.Contains(nt, nc) {
		return 100
	}
	ct, tt := albumTokens(candidate), albumTokens(target)
	n := 0
	for t := range tt {
		if ct[t] {
			n++
		}
	}
	return n
}

func stripParens(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			if depth > 0 {
				depth--
			}
		default:
			if depth == 0 {
				b.WriteRune(r)
			}
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

func searchTitleVariants(title string) []string {

	var stripped []string
	seen := map[string]bool{title: true}
	add := func(s string) {
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		stripped = append(stripped, s)
	}
	add(stripStructuralTitlePrefix(title))
	add(stripParens(title))

	if len(stripped) == 0 {
		return []string{title}
	}
	if len(titleVersionTags(title)) > 0 {
		return append([]string{title}, stripped...)
	}
	return append(stripped, title)
}

var structuralTitlePrefixes = []string{"medley", "interlude"}

func stripStructuralTitlePrefix(title string) string {
	i := strings.Index(title, ":")
	if i <= 0 {
		return title
	}
	label := strings.ToLower(strings.TrimSpace(title[:i]))
	for _, p := range structuralTitlePrefixes {
		if label == p {
			return strings.TrimSpace(title[i+1:])
		}
	}
	return title
}

var distinctRecordingVersionTags = []string{
	"demo", "original version", "single version",
	"live", "unplugged", "acoustic", "instrumental", "karaoke",
	"remix", "extended", "radio edit", "alternate", "alternative version",
	"rehearsal", "reprise", "a cappella", "acapella",

	"club mix", "radio mix", "house mix", "dub mix", "dance mix", "vocal mix", "club edit",

	"现场", "不插电", "伴奏", "纯音乐", "清唱", "混音", "加长版", "阿卡贝拉", "排练",

	"day version", "night version",

	"edit",
}

var wordOnlyVersionTags = map[string]bool{"edit": true}

var versionTagAliases = map[string]string{
	"现场":       "live",
	"不插电":      "unplugged",
	"伴奏":       "instrumental",
	"纯音乐":      "instrumental",
	"清唱":       "a cappella",
	"阿卡贝拉":     "a cappella",
	"acapella": "a cappella",
	"混音":       "remix",
	"加长版":      "extended",
	"排练":       "rehearsal",
}

func canonicalVersionTag(tag string) string {
	if c, ok := versionTagAliases[tag]; ok {
		return c
	}
	return tag
}

var djRemixTagPattern = regexp.MustCompile(`(?i)dj[\p{L}0-9.]*版`)

const djRemixVersionTag = "dj混音"

func titleVersionTags(title string) map[string]bool {
	out := map[string]bool{}
	for _, seg := range titleQualifierSegments(title) {
		n := normLoose(seg)
		if n == "" {
			continue
		}
		var wordTags map[string]bool
		for _, tag := range distinctRecordingVersionTags {

			if wordOnlyVersionTags[tag] {
				if wordTags == nil {
					wordTags = segmentVersionTags(seg)
				}
				if wordTags[canonicalVersionTag(tag)] {
					out[canonicalVersionTag(tag)] = true
				}
				continue
			}
			if strings.Contains(n, normLoose(tag)) {
				out[canonicalVersionTag(tag)] = true
			}
		}
		if djRemixTagPattern.MatchString(n) {
			out[djRemixVersionTag] = true
		}
		if lang := languageVersionTagOfSegment(seg); lang != "" {
			out[lang] = true
		}
	}
	return out
}

func titleQualifierSegments(title string) []string {
	segs := parentheticalSegments(title)
	if i := strings.LastIndex(title, " - "); i >= 0 {
		segs = append(segs, title[i+3:])
	}
	return segs
}

func parentheticalSegments(s string) []string {
	var out []string
	var cur strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '[', '{':
			depth++
			if depth == 1 {
				cur.Reset()
				continue
			}
		case ')', ']', '}':
			if depth > 0 {
				depth--
				if depth == 0 {
					out = append(out, cur.String())
					continue
				}
			}
		}
		if depth > 0 {
			cur.WriteRune(r)
		}
	}

	if depth > 0 && cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

func versionTagsMismatch(localTitle, localAlbum, candidateTitle, candidateAlbum string) bool {
	return versionTagsMismatchIgnoringLanguage(localTitle, localAlbum, candidateTitle, candidateAlbum, false)
}

func versionTagsMismatchIgnoringLanguage(localTitle, localAlbum, candidateTitle, candidateAlbum string, ignoreLanguage bool) bool {
	if strings.TrimSpace(candidateTitle) == "" && strings.TrimSpace(candidateAlbum) == "" {
		return false
	}
	local, cand := recordingVersionTags(localTitle, localAlbum), recordingVersionTags(candidateTitle, candidateAlbum)
	if ignoreLanguage {
		local, cand = withoutLanguageVersionTags(local), withoutLanguageVersionTags(cand)
	}
	if len(local) != len(cand) {
		return true
	}
	for tag := range local {
		if !cand[tag] {
			return true
		}
	}
	return false
}

func versionTagsIn(fields ...string) map[string]bool {
	out := map[string]bool{}
	for _, f := range fields {
		for tag := range titleVersionTags(f) {
			out[tag] = true
		}
	}
	return out
}

func recordingVersionTags(title, album string) map[string]bool {
	out := recordingVersionTagsIn(title, album)
	if !out["live"] && albumHasCJKLiveMarker(stripParens(album)) {
		out["live"] = true
	}
	if !out["live"] && (qualifierDeclaresCJKLive(title) || qualifierDeclaresCJKLive(album)) {
		out["live"] = true
	}
	return out
}

func qualifierDeclaresCJKLive(s string) bool {
	for _, seg := range titleQualifierSegments(s) {
		n := normLoose(seg)
		if n == "" {
			continue
		}
		for _, m := range cjkLiveAlbumMarkers {
			if strings.HasSuffix(n, m) {
				return true
			}
		}
	}
	return false
}

func recordingVersionTagsIn(title, album string) map[string]bool {
	out := titleVersionTags(title)
	for tag := range withoutLanguageVersionTags(titleVersionTags(album)) {
		out[tag] = true
	}
	return out
}

const (
	languageVersionTagCantonese = "粤语"
	languageVersionTagMandarin  = "国语"

	languageVersionTagEnglish  = "英语"
	languageVersionTagJapanese = "日语"
	languageVersionTagKorean   = "韩语"
)

var languageVersionTagSet = map[string]bool{
	languageVersionTagCantonese: true,
	languageVersionTagMandarin:  true,
	languageVersionTagEnglish:   true,
	languageVersionTagJapanese:  true,
	languageVersionTagKorean:    true,
}

func languageVersionTagOfSegment(seg string) string {
	n := normLoose(seg)
	switch n {
	case "粤":
		return languageVersionTagCantonese
	case "国":
		return languageVersionTagMandarin
	}
	switch {
	case strings.Contains(n, "粤语") || strings.Contains(n, "cantonese"):
		return languageVersionTagCantonese

	case strings.Contains(n, "国语") || strings.Contains(n, "mandarin") ||
		strings.Contains(n, "中文") || strings.Contains(n, "chinese") || strings.Contains(n, "华语"):
		return languageVersionTagMandarin
	case strings.Contains(n, "英语") || strings.Contains(n, "英文") || strings.Contains(n, "english"):
		return languageVersionTagEnglish

	case strings.Contains(n, "日语") || strings.Contains(n, "日文") ||
		strings.Contains(n, "日本语") || strings.Contains(n, "japanese"):
		return languageVersionTagJapanese
	case strings.Contains(n, "韩语") || strings.Contains(n, "韩文") || strings.Contains(n, "korean"):
		return languageVersionTagKorean
	}
	return ""
}

func withoutLanguageVersionTags(tags map[string]bool) map[string]bool {
	out := make(map[string]bool, len(tags))
	for tag := range tags {
		if languageVersionTagSet[tag] {
			continue
		}
		out[tag] = true
	}
	return out
}

func declaredLanguageVersion(title string) string {
	found := map[string]bool{}
	for tag := range titleVersionTags(title) {
		if languageVersionTagSet[tag] {
			found[tag] = true
		}
	}
	if len(found) != 1 {
		return ""
	}
	for tag := range found {
		return tag
	}
	return ""
}

func candidateLanguageVersion(c lyricCandidate) string {
	switch c.language {
	case songLanguageCantonese:
		return languageVersionTagCantonese
	case songLanguageMandarin:
		return languageVersionTagMandarin
	}
	return declaredLanguageVersion(c.title)
}

const localLanguageInferenceExactAlbumScore = 200

const (
	localLanguageInferenceFitTolerance = 0.005
	localLanguageInferenceGapTolerance = 0.015
)

func inferLocalLanguageVersion(localTitle, localAlbum string, durationSecs float64, candidates []lyricCandidate) string {
	if lang := declaredLanguageVersion(localTitle); lang != "" {
		return lang
	}
	if durationSecs <= 0 {
		return ""
	}
	relDiff := func(c lyricCandidate) float64 {
		return math.Abs(c.sourceReportedDurationSecs-durationSecs) / math.Max(c.sourceReportedDurationSecs, durationSecs)
	}

	exact := map[string]bool{}
	for _, c := range candidates {
		if albumScore(c.album, localAlbum) < localLanguageInferenceExactAlbumScore || c.sourceReportedDurationSecs <= 0 {
			continue
		}
		if relDiff(c) > localLanguageInferenceFitTolerance {
			continue
		}
		if lang := candidateLanguageVersion(c); lang != "" {
			exact[lang] = true
		}
	}
	if len(exact) == 1 {
		for lang := range exact {
			return lang
		}
	}
	if len(exact) > 1 {
		return ""
	}
	closest := map[string]float64{}
	for _, c := range candidates {
		if c.sourceReportedDurationSecs <= 0 {
			continue
		}
		lang := candidateLanguageVersion(c)
		if lang == "" {
			continue
		}
		diff := relDiff(c)
		if cur, ok := closest[lang]; !ok || diff < cur {
			closest[lang] = diff
		}
	}
	if len(closest) < 2 {
		return ""
	}
	best, bestDiff := "", math.Inf(1)
	for lang, diff := range closest {
		if diff < bestDiff {
			best, bestDiff = lang, diff
		}
	}
	if bestDiff > localLanguageInferenceFitTolerance {
		return ""
	}
	for lang, diff := range closest {
		if lang != best && diff < localLanguageInferenceGapTolerance {
			return ""
		}
	}
	return best
}

func applyLanguageVersionVerdicts(localTitle, localAlbum string, durationSecs float64, candidates []lyricCandidate) {
	local := inferLocalLanguageVersion(localTitle, localAlbum, durationSecs, candidates)
	for i := range candidates {
		candidates[i].languageVersionMismatch, candidates[i].languageVersionAgrees = false, false
		if local == "" {
			continue
		}
		lang := candidateLanguageVersion(candidates[i])
		if lang == "" {
			continue
		}
		if lang == local {
			candidates[i].languageVersionAgrees = true
		} else {
			candidates[i].languageVersionMismatch = true
		}
	}
}

const versionMismatchPenalty = 600

var sameRecordingExtraTagWhitelist = map[string]bool{

	"acoustic": true, "unplugged": true,
}

var sameRecordingNamingOnlyTags = map[string]bool{
	"single version": true,
}

func sameRecordingDespiteVersionTags(
	localTitle, localAlbum string, localDurationSecs float64,
	candTitle, candAlbum string, candDurationSecs float64,
) bool {
	return sameRecordingDespiteVersionTagsIgnoringLanguage(localTitle, localAlbum, localDurationSecs,
		candTitle, candAlbum, candDurationSecs, false)
}

func sameRecordingDespiteVersionTagsIgnoringLanguage(
	localTitle, localAlbum string, localDurationSecs float64,
	candTitle, candAlbum string, candDurationSecs float64,
	ignoreLanguage bool,
) bool {
	if localDurationSecs <= 0 || candDurationSecs <= 0 {
		return false
	}
	larger := math.Max(localDurationSecs, candDurationSecs)
	if math.Abs(localDurationSecs-candDurationSecs)/larger > 0.01 {
		return false
	}
	if albumScore(candAlbum, localAlbum) < 1 {
		return false
	}

	localParen := recordingVersionTagsIn(localTitle, localAlbum)
	local := recordingVersionTags(localTitle, localAlbum)
	cand := recordingVersionTags(candTitle, candAlbum)
	if ignoreLanguage {
		localParen, local, cand = withoutLanguageVersionTags(localParen), withoutLanguageVersionTags(local), withoutLanguageVersionTags(cand)
	}
	for tag := range localParen {
		if !cand[tag] && !sameRecordingNamingOnlyTags[tag] {
			return false
		}
	}
	for tag := range cand {
		if !local[tag] && !sameRecordingExtraTagWhitelist[tag] && !sameRecordingNamingOnlyTags[tag] {
			return false
		}
	}
	return true
}

const liveAlbumConflictPenalty = 600

var liveAlbumMarkerTokens = map[string]bool{
	"live": true, "concert": true, "tour": true,
	"现场": true, "演唱会": true, "音乐会": true, "演出": true, "巡演": true, "巡回": true,
}

var cjkLiveAlbumMarkers = []string{"现场", "演唱会", "音乐会"}

func albumHasLiveMarker(album string) bool {
	for t := range albumTokens(toSimplified(album)) {
		if liveAlbumMarkerTokens[t] {
			return true
		}
	}
	return albumHasCJKLiveMarker(album)
}

func albumHasCJKLiveMarker(album string) bool {
	for t := range albumTokens(toSimplified(album)) {
		for _, m := range cjkLiveAlbumMarkers {
			if strings.Contains(t, m) {
				return true
			}
		}
	}
	return false
}

func albumIdentityTokens(artist, album string) map[string]bool {
	a := strings.ToLower(toSimplified(album))
	if ar := strings.ToLower(strings.TrimSpace(toSimplified(artist))); ar != "" {
		a = strings.ReplaceAll(a, ar, " ")
	}
	out := map[string]bool{}
	for t := range albumTokens(a) {
		if !liveAlbumMarkerTokens[t] {
			out[t] = true
		}
	}
	return out
}

func liveIdentityTokens(artist, title, album string) map[string]bool {
	out := albumIdentityTokens(artist, album)
	for _, seg := range titleQualifierSegments(title) {
		if !albumHasLiveMarker(seg) {
			continue
		}
		for t := range albumIdentityTokens(artist, seg) {
			out[t] = true
		}
	}
	return out
}

func liveAlbumIdentityConflict(localArtist, localTitle, localAlbum, candTitle, candAlbum string) bool {

	if strings.TrimSpace(localAlbum) == "" {
		return false
	}
	if !albumHasLiveMarker(localAlbum) {
		return false
	}
	candTags := versionTagsIn(candTitle, candAlbum)

	if !candTags["live"] && !albumHasLiveMarker(candAlbum) {
		return false
	}
	lt := liveIdentityTokens(localArtist, localTitle, localAlbum)
	ct := liveIdentityTokens(localArtist, candTitle, candAlbum)
	if len(lt) == 0 || len(ct) == 0 {
		return false
	}
	for t := range ct {
		if lt[t] {
			return false
		}
	}
	return true
}

func lyricTitleAccepted(candidateTitle, localTitle string) bool {
	nc, nl := normLoose(candidateTitle), normLoose(localTitle)
	if nc == "" || nl == "" {
		return false
	}
	if nc == nl {
		return true
	}
	sc, sl := normLoose(stripParens(candidateTitle)), normLoose(stripParens(localTitle))
	if sc != "" && sl != "" && sc == sl {
		return true
	}

	fc := normLoose(stripStructuralTitlePrefix(stripParens(candidateTitle)))
	fl := normLoose(stripStructuralTitlePrefix(stripParens(localTitle)))
	if fc != "" && fl != "" && fc == fl {
		return true
	}

	return bilingualTitleEqual(sc, sl) || bilingualTitleEqual(nc, nl)
}

var lrcMetaTagPrefixRe = regexp.MustCompile(`^\[[A-Za-z_]+:`)

func isLRCMetaTagLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasSuffix(trimmed, "]") && lrcMetaTagPrefixRe.MatchString(trimmed)
}

func lyricConsensusBody(lyrics string) string {

	speakers := lyricSpeakerLabels(lyrics)
	var b strings.Builder
	for _, line := range splitLyricLines(lyrics) {

		if isLRCMetaTagLine(line) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		if label, rest, ok := lyricSplitLabel(text); ok && speakers[label] {

			if rest != "" {
				b.WriteString(normLoose(rest))
			}
			continue
		}
		if isCreditLine(text) {
			continue
		}
		b.WriteString(normLoose(text))
	}
	return b.String()
}

func lyricGram3Set(s string) map[string]struct{} {
	rs := []rune(s)
	out := make(map[string]struct{}, len(rs))
	for i := 0; i+3 <= len(rs); i++ {
		out[string(rs[i:i+3])] = struct{}{}
	}
	return out
}

func gramJaccard(a, b map[string]struct{}) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	small, big := a, b
	if len(small) > len(big) {
		small, big = big, small
	}
	inter := 0
	for g := range small {
		if _, ok := big[g]; ok {
			inter++
		}
	}
	union := len(a) + len(b) - inter
	if union == 0 {
		return 0
	}
	return float64(inter) / float64(union)
}

const (
	lyricConsensusSimThreshold = 0.55
	lyricConsensusMinBodyRunes = 30
)

func lyricSourceConsensusFamily(source string) string {
	switch source {
	case lyricSourceDeezer, lyricSourceLyricFind:
		return lyricSourceLyricFind
	}
	return source
}

func contentConsensusPeers(localArtist, localTitle string, candidates []lyricCandidate, durationSecs float64) map[string][]string {
	if len(candidates) < 2 {
		return map[string][]string{}
	}
	type member struct {
		source  string
		grams   map[string]struct{}
		last    float64
		hasLast bool
	}
	members := make([]member, 0, len(candidates))

	anyFits := false
	for _, c := range candidates {
		if durationSecs > 0 {
			if last, ok := lastLRCTimestampSecs(c.lyrics); ok && durationFits(last, durationSecs) {
				anyFits = true
			}
		}
	}
	for _, c := range candidates {

		if !isTimedLRC(c.lyrics) || isCreditOnlyLRC(c.lyrics) {
			continue
		}
		last, hasLast := lastLRCTimestampSecs(c.lyrics)
		var grams map[string]struct{}
		if body := lyricConsensusBody(c.lyrics); len([]rune(body)) >= lyricConsensusMinBodyRunes {
			grams = lyricGram3Set(body)
		}
		members = append(members, member{c.source, grams, last, hasLast})
	}
	peers := map[string][]string{}
	for i := range members {
		if members[i].grams == nil {
			continue
		}
		var agree []string

		seenFamily := map[string]bool{lyricSourceConsensusFamily(members[i].source): true}
		for j := range members {
			if i == j || members[j].grams == nil {
				continue
			}
			fam := lyricSourceConsensusFamily(members[j].source)
			if seenFamily[fam] {
				continue
			}
			if gramJaccard(members[i].grams, members[j].grams) >= lyricConsensusSimThreshold {
				agree = append(agree, members[j].source)
				seenFamily[fam] = true
			}
		}
		peers[members[i].source] = agree
	}
	if durationSecs > 0 {
		for i := range members {
			if !members[i].hasLast {
				continue
			}
			fits := durationFits(members[i].last, durationSecs)

			if (anyFits && !fits) || members[i].last > durationSecs+lyricOvershootToleranceSecs {
				peers[members[i].source] = nil
			}
		}
	}
	return peers
}

func titleMatchTierPoints(candidateTitle, localTitle string) int {
	return titleMatchTierPointsIgnoringLanguage(candidateTitle, localTitle, false)
}

func titleMatchTierPointsIgnoringLanguage(candidateTitle, localTitle string, ignoreLanguage bool) int {
	nct, nlt := normLoose(candidateTitle), normLoose(localTitle)
	if nct == "" || nlt == "" {
		return 0
	}
	if nct == nlt {
		return 120
	}
	sc, sl := normLoose(stripParens(candidateTitle)), normLoose(stripParens(localTitle))
	if sc != "" && sl != "" && sc == sl {
		ct, lt := parenOnlyVersionTags(candidateTitle), parenOnlyVersionTags(localTitle)
		if ignoreLanguage {
			ct, lt = withoutLanguageVersionTags(ct), withoutLanguageVersionTags(lt)
		}
		if len(ct) == 0 && len(lt) == 0 {
			return 120
		}
		return 60
	}
	if bilingualTitleEqual(sc, sl) || bilingualTitleEqual(nct, nlt) {
		return 30
	}
	return 0
}

func parenOnlyVersionTags(title string) map[string]bool {
	out := map[string]bool{}
	for _, seg := range parentheticalSegments(title) {
		for tag := range segmentVersionTags(seg) {
			out[tag] = true
		}
	}
	return out
}

func segmentVersionTags(seg string) map[string]bool {
	toks := strings.FieldsFunc(strings.ToLower(seg), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	joined := strings.Join(toks, "")
	out := map[string]bool{}
	for _, tag := range distinctRecordingVersionTags {

		if !isASCIITag(tag) {
			if strings.Contains(joined, tag) {
				out[canonicalVersionTag(tag)] = true
			}
			continue
		}
		tagToks := strings.Fields(tag)
		for i := 0; i+len(tagToks) <= len(toks); i++ {
			match := true
			for j, tt := range tagToks {
				if toks[i+j] != tt {
					match = false
					break
				}
			}
			if match {
				out[canonicalVersionTag(tag)] = true
				break
			}
		}
	}
	if djRemixTagPattern.MatchString(joined) {
		out[djRemixVersionTag] = true
	}

	if lang := languageVersionTagOfSegment(seg); lang != "" {
		out[lang] = true
	}
	return out
}

func isASCIITag(tag string) bool {
	for _, r := range tag {
		if r > unicode.MaxASCII {
			return false
		}
	}
	return true
}

func timedNonEmptyLRCLines(lrc string) int {
	n := 0
	for _, line := range strings.Split(lrc, "\n") {
		if !lrcTimestampRe.MatchString(line) {
			continue
		}
		if strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, "")) != "" {
			n++
		}
	}
	return n
}

func kanaRatio(s string) float64 {
	stripped := lrcTimestampRe.ReplaceAllString(s, "")
	total, kana := 0, 0
	for _, r := range stripped {
		if unicode.IsSpace(r) {
			continue
		}
		total++
		if (r >= 0x3041 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF) {
			kana++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(kana) / float64(total)
}

func usableValueAdd(lyrics, tr, trLang, roma, targetLang string) (usableTr, usableRoma bool) {

	baseLang := func(s string) string {
		if i := strings.IndexAny(s, "-_"); i >= 0 {
			s = s[:i]
		}
		return strings.ToLower(strings.TrimSpace(s))
	}

	looksChineseOriginal := cjkRatio(lyrics) > 0.5 && kanaRatio(lyrics) <= 0.05
	if tr != "" && targetLang != "" &&
		baseLang(trLang) != "" && baseLang(trLang) == baseLang(targetLang) &&
		isTimedLRC(tr) &&
		2*timedNonEmptyLRCLines(tr) >= timedNonEmptyLRCLines(lyrics) &&
		!(baseLang(targetLang) == "zh" && looksChineseOriginal) {
		usableTr = true
	}
	if roma != "" && isTimedLRC(roma) && kanaRatio(lyrics) > 0.05 {
		usableRoma = true
	}
	return
}

func bilingualTitleEqual(a, b string) bool {
	short, long := a, b
	if len(short) > len(long) {
		short, long = long, short
	}
	if short == "" || len(short) == len(long) || !strings.HasPrefix(long, short) {
		return false
	}
	if !containsHan(short) {
		return false
	}
	for _, r := range long[len(short):] {
		if r < 'a' || r > 'z' {
			return false
		}
	}
	return true
}

const wordTimingCoverageFloor = 0.5

func usableWordTiming(lyrics, yrc string) bool {
	if yrc == "" {
		return false
	}
	lrcEnd := lastLRCTimestampMs(lyrics)
	yrcEnd := lastYRCTimestampMs(yrc)
	if lrcEnd <= 0 || yrcEnd <= 0 {
		return true
	}
	return float64(yrcEnd) >= float64(lrcEnd)*wordTimingCoverageFloor
}

func usableYRC(lyrics, yrc string) string {
	if !usableWordTiming(lyrics, yrc) {
		return ""
	}
	return yrc
}

func lastLRCTimestampMs(lyrics string) int {
	best := 0
	for _, line := range strings.Split(lyrics, "\n") {
		m := lrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		mm, _ := strconv.Atoi(m[1])
		ss, _ := strconv.Atoi(m[2])
		frac, _ := strconv.Atoi(m[3])
		ms := (mm*60+ss)*1000 + frac*10
		if len(m[3]) == 3 {
			ms = (mm*60+ss)*1000 + frac
		}
		if ms > best {
			best = ms
		}
	}
	return best
}

func lastYRCTimestampMs(yrc string) int {
	best := 0
	for _, line := range strings.Split(yrc, "\n") {
		m := yrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		start, _ := strconv.Atoi(m[1])
		dur, _ := strconv.Atoi(m[2])
		if start+dur > best {
			best = start + dur
		}
	}
	return best
}

var (
	lrcLineTimeRegex = regexp.MustCompile(`^\[(\d+):(\d+)[.:](\d+)\]`)
	yrcLineTimeRegex = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
)
