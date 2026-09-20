package main

import (
	"hash/fnv"
	"math/rand"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode"
)

const (
	goldenHanPoolLo      = 0x3400
	goldenHanPoolHi      = 0x4DBF
	goldenHiraganaLo     = 0x3041
	goldenHiraganaHi     = 0x3096
	goldenKatakanaLo     = 0x30A1
	goldenKatakanaHi     = 0x30FA
	goldenHangulLo       = 0xAC00
	goldenHangulHi       = 0xD7A3
	goldenScrambleMarker = "纯音乐"
)

var goldenHanPoolOnce sync.Once
var goldenHanPoolCache []rune

func goldenHanPool() []rune {
	goldenHanPoolOnce.Do(func() { goldenHanPoolCache = buildGoldenHanPool() })
	return goldenHanPoolCache
}

func buildGoldenHanPool() []rune {
	forbidden := map[rune]bool{}
	for k, v := range t2sCharMap {
		for _, r := range k + v {
			forbidden[r] = true
		}
	}
	for k, v := range t2sPhraseMap {
		for _, r := range k + v {
			forbidden[r] = true
		}
	}
	for k, v := range hanVariantMap {
		forbidden[k] = true
		forbidden[v] = true
	}
	var pool []rune
	for r := rune(goldenHanPoolLo); r <= goldenHanPoolHi; r++ {
		if forbidden[r] || !unicode.Is(unicode.Han, r) || !unicode.IsLetter(r) {
			continue
		}
		pool = append(pool, r)
	}
	return pool
}

func goldenRangePool(lo, hi rune) []rune {
	pool := make([]rune, 0, hi-lo+1)
	for r := lo; r <= hi; r++ {
		pool = append(pool, r)
	}
	return pool
}

type goldenRuneClass int

const (
	goldenClassOther goldenRuneClass = iota
	goldenClassHan
	goldenClassLatin
	goldenClassHiragana
	goldenClassKatakana
	goldenClassHangul
)

func goldenClassify(r rune) goldenRuneClass {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z':
		return goldenClassLatin
	case r >= goldenHiraganaLo && r <= goldenHiraganaHi:
		return goldenClassHiragana
	case r >= goldenKatakanaLo && r <= goldenKatakanaHi:
		return goldenClassKatakana
	case r >= goldenHangulLo && r <= goldenHangulHi:
		return goldenClassHangul
	case unicode.Is(unicode.Han, r):
		return goldenClassHan
	}
	return goldenClassOther
}

type goldenSeg struct {
	text     string
	scramble bool
}

var goldenLRCStampPrefixRe = regexp.MustCompile(`^(?:\[\d{1,2}:\d{2}[.:]\d{1,3}\])+`)
var goldenYRCHeadRe = regexp.MustCompile(`^\[\d+,\d+\]`)
var goldenYRCWordRe = regexp.MustCompile(`\(\d+,\d+(?:,\d+)?\)`)

func goldenSegmentLRCLine(line string) []goldenSeg {
	var segs []goldenSeg
	keep := func(s string) {
		if s != "" {
			segs = append(segs, goldenSeg{text: s})
		}
	}
	scramble := func(s string) {
		if s != "" {
			segs = append(segs, goldenSeg{text: s, scramble: true})
		}
	}
	rest := line

	lead := 0
	for _, r := range rest {
		if r == '\uFEFF' || unicode.IsSpace(r) {
			lead += len(string(r))
			continue
		}
		break
	}
	keep(rest[:lead])
	rest = rest[lead:]

	if m := goldenLRCStampPrefixRe.FindString(rest); m != "" {
		keep(m)
		rest = rest[len(m):]
	}
	trimmed := strings.TrimSpace(rest)
	if trimmed == "" {
		keep(rest)
		return segs
	}
	if isLRCMetaTagLine(trimmed) {
		lower := strings.ToLower(trimmed)
		if strings.HasPrefix(lower, "[kana:") && strings.HasSuffix(trimmed, "]") {
			start := strings.Index(rest, "[")
			head := rest[:start+len("[kana:")]
			tail := rest[strings.LastIndex(rest, "]"):]
			keep(head)
			scramble(rest[len(head) : len(rest)-len(tail)])
			keep(tail)
			return segs
		}
		keep(rest)
		return segs
	}
	if strings.Contains(trimmed, goldenScrambleMarker) {
		keep(rest)
		return segs
	}

	if label, _, ok := lyricSplitLabel(trimmed); ok {
		if lyricKnownSpeakerSet[label] || !lyricPlausibleSpeakerName(label) {
			off := strings.Index(rest, trimmed)
			n := goldenLabelPrefixLen(trimmed)
			keep(rest[:off+n])
			scramble(rest[off+n:])
			return segs
		}
	} else if m := creditLineRe.FindStringIndex(trimmed); m != nil {

		off := strings.Index(rest, trimmed)
		keep(rest[:off+m[1]])
		scramble(rest[off+m[1]:])
		return segs
	}
	scramble(rest)
	return segs
}

func goldenLabelPrefixLen(trimmed string) int {
	for i, r := range trimmed {
		if r == ':' || r == '：' {
			return i + len(string(r))
		}
	}
	return 0
}

func goldenSegmentYRCLine(line string) []goldenSeg {
	trimmedLead := strings.TrimLeft(line, "\uFEFF \t")
	if strings.HasPrefix(trimmedLead, "{") {

		return []goldenSeg{{text: line}}
	}
	if !goldenYRCHeadRe.MatchString(trimmedLead) {
		return goldenSegmentLRCLine(line)
	}
	var segs []goldenSeg
	rest := line
	head := goldenYRCHeadRe.FindStringIndex(strings.TrimLeft(line, "\uFEFF \t"))
	lead := len(line) - len(strings.TrimLeft(line, "\uFEFF \t"))
	segs = append(segs, goldenSeg{text: rest[:lead+head[1]]})
	rest = rest[lead+head[1]:]
	for rest != "" {
		m := goldenYRCWordRe.FindStringIndex(rest)
		if m == nil {
			segs = append(segs, goldenYRCTextSeg(rest))
			break
		}
		if m[0] > 0 {
			segs = append(segs, goldenYRCTextSeg(rest[:m[0]]))
		}
		segs = append(segs, goldenSeg{text: rest[m[0]:m[1]]})
		rest = rest[m[1]:]
	}
	return segs
}

func goldenYRCTextSeg(s string) goldenSeg {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" || strings.Contains(trimmed, goldenScrambleMarker) {
		return goldenSeg{text: s}
	}
	if label, rest, ok := lyricSplitLabel(trimmed); ok && rest == "" && (lyricKnownSpeakerSet[label] || !lyricPlausibleSpeakerName(label)) {
		return goldenSeg{text: s}
	}
	return goldenSeg{text: s, scramble: true}
}

func goldenSegmentText(text string, yrc bool) [][]goldenSeg {
	lines := strings.Split(text, "\n")
	out := make([][]goldenSeg, 0, len(lines))
	for _, line := range lines {

		if yrc {
			out = append(out, goldenSegmentYRCLine(line))
		} else {
			out = append(out, goldenSegmentLRCLine(line))
		}
	}
	return out
}

func goldenCanon(s string) string {
	return foldDiacritics(toSimplified(s))
}

type goldenScrambler struct {
	han, hira, kata, hangul map[rune]rune
	latin                   [26]rune
}

func newGoldenScrambler(seed string, texts []goldenText) *goldenScrambler {
	h := fnv.New64a()
	h.Write([]byte(seed))
	rng := rand.New(rand.NewSource(int64(h.Sum64())))

	present := map[goldenRuneClass]map[rune]bool{
		goldenClassHan: {}, goldenClassHiragana: {}, goldenClassKatakana: {}, goldenClassHangul: {},
	}
	for _, t := range texts {
		for _, segs := range goldenSegmentText(t.text, t.yrc) {
			for _, seg := range segs {
				if !seg.scramble {
					continue
				}
				for _, r := range goldenCanon(seg.text) {
					c := goldenClassify(r)
					if m, ok := present[c]; ok {
						m[r] = true
					}
				}
			}
		}
	}
	assign := func(set map[rune]bool, pool []rune) map[rune]rune {
		src := make([]rune, 0, len(set))
		for r := range set {
			src = append(src, r)
		}
		sort.Slice(src, func(i, j int) bool { return src[i] < src[j] })
		shuffled := append([]rune(nil), pool...)
		rng.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })
		m := make(map[rune]rune, len(src))
		for i, r := range src {
			if i < len(shuffled) {
				m[r] = shuffled[i]
			} else {
				m[r] = r
			}
		}
		return m
	}
	s := &goldenScrambler{
		han:    assign(present[goldenClassHan], goldenHanPool()),
		hira:   assign(present[goldenClassHiragana], goldenRangePool(goldenHiraganaLo, goldenHiraganaHi)),
		kata:   assign(present[goldenClassKatakana], goldenRangePool(goldenKatakanaLo, goldenKatakanaHi)),
		hangul: assign(present[goldenClassHangul], goldenRangePool(goldenHangulLo, goldenHangulHi)),
	}
	perm := rng.Perm(26)
	for i, p := range perm {
		s.latin[i] = rune('a' + p)
	}
	return s
}

type goldenText struct {
	text string
	yrc  bool
}

func (s *goldenScrambler) mapRune(r rune) rune {
	switch goldenClassify(r) {
	case goldenClassLatin:
		if r >= 'A' && r <= 'Z' {
			return unicode.ToUpper(s.latin[r-'A'])
		}
		return s.latin[r-'a']
	case goldenClassHan:
		if m, ok := s.han[r]; ok {
			return m
		}
	case goldenClassHiragana:
		if m, ok := s.hira[r]; ok {
			return m
		}
	case goldenClassKatakana:
		if m, ok := s.kata[r]; ok {
			return m
		}
	case goldenClassHangul:
		if m, ok := s.hangul[r]; ok {
			return m
		}
	}
	return r
}

func (s *goldenScrambler) scrambleSeg(text string) string {
	var b strings.Builder
	for _, r := range goldenCanon(text) {
		b.WriteRune(s.mapRune(r))
	}
	return b.String()
}

func (s *goldenScrambler) scrambleText(text string, yrc bool) string {
	if text == "" {
		return ""
	}
	lines := goldenSegmentText(text, yrc)
	var b strings.Builder
	for i, segs := range lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		for _, seg := range segs {
			if seg.scramble {
				b.WriteString(s.scrambleSeg(seg.text))
			} else {
				b.WriteString(seg.text)
			}
		}
	}
	return b.String()
}

func scrambleLyricRound(raw map[string]lyricSourceResult, seed string) map[string]lyricSourceResult {
	var texts []goldenText
	for _, r := range raw {
		texts = append(texts,
			goldenText{r.lyr, false}, goldenText{r.yrc, true}, goldenText{r.tr, false}, goldenText{r.roma, false},
			goldenText{r.ne.Lyrics, false}, goldenText{r.ne.Trans, false}, goldenText{r.ne.Roma, false}, goldenText{r.ne.YRC, true},
			goldenText{r.amll.lrc, false}, goldenText{r.amll.yrc, true}, goldenText{r.amll.tr, false},
		)
	}

	s := newGoldenScrambler(seed, texts)
	out := make(map[string]lyricSourceResult, len(raw))
	for src, r := range raw {
		r.lyr = s.scrambleText(r.lyr, false)
		r.yrc = s.scrambleText(r.yrc, true)
		r.tr = s.scrambleText(r.tr, false)
		r.roma = s.scrambleText(r.roma, false)
		r.ne.Lyrics = s.scrambleText(r.ne.Lyrics, false)
		r.ne.Trans = s.scrambleText(r.ne.Trans, false)
		r.ne.Roma = s.scrambleText(r.ne.Roma, false)
		r.ne.YRC = s.scrambleText(r.ne.YRC, true)
		r.amll.lrc = s.scrambleText(r.amll.lrc, false)
		r.amll.yrc = s.scrambleText(r.amll.yrc, true)
		r.amll.tr = s.scrambleText(r.amll.tr, false)
		out[src] = r
	}
	return out
}

var goldenCommonEnglish = map[string]bool{
	"the": true, "you": true, "and": true, "love": true, "that": true, "with": true,
	"your": true, "this": true, "have": true, "what": true, "never": true, "when": true,
}

func goldenFindUnscrambledLine(text string) (string, bool) {
	if text == "" {
		return "", false
	}
	yrc := false
	for _, line := range strings.Split(text, "\n") {
		if goldenYRCHeadRe.MatchString(strings.TrimLeft(line, "\uFEFF \t")) {
			yrc = true
			break
		}
	}
	for _, line := range strings.Split(text, "\n") {
		var segs []goldenSeg
		if yrc {
			segs = goldenSegmentYRCLine(line)
		} else {
			segs = goldenSegmentLRCLine(line)
		}
		hits := map[string]bool{}
		for _, seg := range segs {
			if !seg.scramble {
				continue
			}
			for _, r := range seg.text {
				if unicode.Is(unicode.Han, r) && !(r >= goldenHanPoolLo && r <= goldenHanPoolHi) {
					return line, true
				}
			}
			for _, w := range strings.FieldsFunc(strings.ToLower(seg.text), func(r rune) bool { return !unicode.IsLetter(r) }) {
				if goldenCommonEnglish[w] {
					hits[w] = true
				}
			}
		}
		if len(hits) >= 3 {
			return line, true
		}
	}
	return "", false
}
