package main

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	amllRawBase     = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"
	amllHTTPTimeout = 8 * time.Second

	amllRoleBackground  = "x-bg"
	amllRoleTranslation = "x-translation"
)

type amllResult struct {
	lrc, yrc, tr string

	hasDuet bool
}

func (r amllResult) empty() bool { return r.lrc == "" && r.yrc == "" }

type ttmlDoc struct {
	XMLName xml.Name    `xml:"tt"`
	Agents  []ttmlAgent `xml:"head>metadata>agent"`
	Divs    []ttmlDiv   `xml:"body>div"`
}

type ttmlAgent struct {
	Type string `xml:"type,attr"`
	ID   string `xml:"http://www.w3.org/XML/1998/namespace id,attr"`
}

type ttmlDiv struct {
	Lines []ttmlLine `xml:"p"`
}

const ttmMetadataNS = "http://www.w3.org/ns/ttml#metadata"

type ttmlNode struct {
	Text string
	Span *ttmlSpan
}

type ttmlLine struct {
	Begin string
	End   string
	Agent string
	Kids  []ttmlNode
}

type ttmlSpan struct {
	Begin string
	End   string
	Role  string
	Kids  []ttmlNode
}

func decodeTTMLKids(d *xml.Decoder) ([]ttmlNode, error) {
	var kids []ttmlNode
	for {
		tok, err := d.Token()
		if err != nil {

			return kids, err
		}
		switch t := tok.(type) {
		case xml.CharData:

			if s := string(t); s != "" {
				kids = append(kids, ttmlNode{Text: s})
			}
		case xml.StartElement:
			if t.Name.Local != "span" {
				if err := d.Skip(); err != nil {
					return kids, err
				}
				continue
			}
			var sp ttmlSpan
			if err := d.DecodeElement(&sp, &t); err != nil {
				return kids, err
			}
			kids = append(kids, ttmlNode{Span: &sp})
		case xml.EndElement:
			return kids, nil
		}
	}
}

func (l *ttmlLine) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	for _, a := range start.Attr {
		switch {
		case a.Name.Space == "" && a.Name.Local == "begin":
			l.Begin = a.Value
		case a.Name.Space == "" && a.Name.Local == "end":
			l.End = a.Value
		case a.Name.Space == ttmMetadataNS && a.Name.Local == "agent":
			l.Agent = a.Value
		}
	}
	kids, err := decodeTTMLKids(d)
	l.Kids = kids
	return err
}

func (s *ttmlSpan) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	for _, a := range start.Attr {
		switch {
		case a.Name.Space == "" && a.Name.Local == "begin":
			s.Begin = a.Value
		case a.Name.Space == "" && a.Name.Local == "end":
			s.End = a.Value
		case a.Name.Space == ttmMetadataNS && a.Name.Local == "role":
			s.Role = a.Value
		}
	}
	kids, err := decodeTTMLKids(d)
	s.Kids = kids
	return err
}

func (s *ttmlSpan) text() string {
	var b strings.Builder
	for _, k := range s.Kids {
		if k.Span == nil {
			b.WriteString(k.Text)
		} else {
			b.WriteString(k.Span.text())
		}
	}
	return b.String()
}

func (s *ttmlSpan) hasSpanKid() bool {
	for _, k := range s.Kids {
		if k.Span != nil {
			return true
		}
	}
	return false
}

type ttmlWord struct {
	begin, end, text string
}

func parseTTMLTime(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return -1
	}
	parts := strings.Split(s, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return -1
	}
	var total float64
	for _, p := range parts {
		v, err := strconv.ParseFloat(p, 64)
		if err != nil || v < 0 {
			return -1
		}
		total = total*60 + v
	}
	return int(total*1000 + 0.5)
}

func formatLRCTime(ms int) string {
	if ms < 0 {
		ms = 0
	}
	return fmt.Sprintf("[%02d:%02d.%02d]", ms/60000, (ms/1000)%60, (ms%1000)/10)
}

func amllSpeakerPrefixes(agents []ttmlAgent) map[string]string {
	var persons []string
	groups := map[string]bool{}
	for _, a := range agents {
		if a.ID == "" {
			continue
		}
		if strings.EqualFold(a.Type, "group") {
			groups[a.ID] = true
		} else {
			persons = append(persons, a.ID)
		}
	}
	out := map[string]string{}
	for id := range groups {
		out[id] = "合"
	}
	if len(persons) < 2 {
		return out
	}
	sort.Strings(persons)
	for i, id := range persons {
		if i >= 8 {
			break
		}
		out[id] = fmt.Sprintf("v%d", i+1)
	}
	return out
}

func flattenTTMLLine(kids []ttmlNode, words *[]ttmlWord, translation *string) {
	for _, k := range kids {
		if k.Span == nil {
			appendTTMLGap(words, k.Text)
			continue
		}
		sp := k.Span
		switch {
		case sp.Role == amllRoleBackground:
			continue
		case sp.Role == amllRoleTranslation:
			if *translation == "" {
				*translation = strings.TrimSpace(sp.text())
			}
		case sp.hasSpanKid():
			flattenTTMLLine(sp.Kids, words, translation)
		default:
			*words = append(*words, ttmlWord{begin: sp.Begin, end: sp.End, text: sp.text()})
		}
	}
}

func appendTTMLGap(words *[]ttmlWord, raw string) {
	if raw == "" || len(*words) == 0 {
		return
	}
	body := strings.TrimSpace(raw)
	last := &(*words)[len(*words)-1]
	if body == "" {
		if !strings.HasSuffix(last.text, " ") {
			last.text += " "
		}
		return
	}
	if strings.HasPrefix(raw, " ") || strings.HasPrefix(raw, "\t") ||
		strings.HasPrefix(raw, "\n") || strings.HasPrefix(raw, "\r") {
		body = " " + body
	}
	if strings.HasSuffix(raw, " ") || strings.HasSuffix(raw, "\t") ||
		strings.HasSuffix(raw, "\n") || strings.HasSuffix(raw, "\r") {
		body += " "
	}
	last.text += body
}

func trimTTMLWordEdges(words []ttmlWord) []ttmlWord {
	const cut = " \t\r\n"
	for len(words) > 0 {
		t := strings.TrimLeft(words[0].text, cut)
		if t == "" {
			words = words[1:]
			continue
		}
		words[0].text = t
		break
	}
	for len(words) > 0 {
		t := strings.TrimRight(words[len(words)-1].text, cut)
		if t == "" {
			words = words[:len(words)-1]
			continue
		}
		words[len(words)-1].text = t
		break
	}
	return words
}

func parseAMLLTTML(raw string) (amllResult, bool) {
	var doc ttmlDoc
	if err := xml.Unmarshal([]byte(raw), &doc); err != nil {
		return amllResult{}, false
	}
	prefixes := amllSpeakerPrefixes(doc.Agents)
	var lrc, yrc, tr strings.Builder
	lines, distinctPersons := 0, map[string]bool{}
	for _, div := range doc.Divs {
		for _, ln := range div.Lines {
			start := parseTTMLTime(ln.Begin)
			if start < 0 {
				continue
			}
			var words []ttmlWord
			translation := ""
			flattenTTMLLine(ln.Kids, &words, &translation)
			words = trimTTMLWordEdges(words)

			prefix := ""
			if p, ok := prefixes[ln.Agent]; ok {
				prefix = p + "："
			}
			if p, ok := prefixes[ln.Agent]; ok && p != "合" {
				distinctPersons[p] = true
			}

			body := ttmlWordsText(words)
			if body == "" {
				body = strings.TrimSpace(ttmlLiteralText(ln.Kids))
			}
			if body == "" {
				continue
			}
			lines++
			lrc.WriteString(formatLRCTime(start) + prefix + body + "\n")
			if translation != "" {
				tr.WriteString(formatLRCTime(start) + translation + "\n")
			}
			if w := buildYRCLine(start, parseTTMLTime(ln.End), prefix, words); w != "" {
				yrc.WriteString(w + "\n")
			}
		}
	}
	if lines == 0 {
		return amllResult{}, false
	}
	return amllResult{
		lrc:     lrc.String(),
		yrc:     yrc.String(),
		tr:      tr.String(),
		hasDuet: len(distinctPersons) >= 2,
	}, true
}

func ttmlWordsText(words []ttmlWord) string {
	var b strings.Builder
	for _, w := range words {
		b.WriteString(w.text)
	}
	return b.String()
}

func ttmlLiteralText(kids []ttmlNode) string {
	var b strings.Builder
	for _, k := range kids {
		if k.Span == nil {
			b.WriteString(k.Text)
		} else {
			b.WriteString(k.Span.text())
		}
	}
	return b.String()
}

func buildYRCLine(startMs, endMs int, prefix string, words []ttmlWord) string {
	type w struct {
		start, dur int
		text       string
	}
	var ws []w
	for _, sp := range words {
		s, e := parseTTMLTime(sp.begin), parseTTMLTime(sp.end)
		if s < 0 || e < s || sp.text == "" {
			continue
		}
		ws = append(ws, w{s, e - s, sp.text})
	}
	if len(ws) == 0 {
		return ""
	}
	if endMs < startMs {
		endMs = ws[len(ws)-1].start + ws[len(ws)-1].dur
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[%d,%d]", startMs, endMs-startMs)
	if prefix != "" {
		fmt.Fprintf(&b, "(%d,0,0)%s", startMs, prefix)
	}
	for _, x := range ws {
		fmt.Fprintf(&b, "(%d,%d,0)%s", x.start, x.dur, x.text)
	}
	return b.String()
}

func amllFetch(ctx context.Context, platformDir, musicID string) (string, bool) {
	if platformDir == "" || musicID == "" {
		return "", false
	}
	url := fmt.Sprintf("%s/%s/%s.ttml", amllRawBase, platformDir, musicID)
	client := lyricHTTPClient(amllHTTPTimeout)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", false
	}
	resp, err := doHTTPTracked(client, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", false
	}
	return string(body), true
}

var amllSkippedForMissingIDs atomic.Bool

func amllSkippedForMissingIDsNow() bool { return amllSkippedForMissingIDs.Load() }

func amllLyric(ctx context.Context, neteaseID, qqID string) amllResult {
	if neteaseID == "" && qqID == "" {
		amllSkippedForMissingIDs.Store(true)
		return amllResult{}
	}
	for _, try := range []struct{ dir, id string }{
		{"ncm-lyrics", neteaseID},
		{"qq-lyrics", qqID},
	} {
		if try.id == "" {
			continue
		}
		raw, ok := amllFetch(ctx, try.dir, try.id)
		if !ok {
			continue
		}
		if r, ok := parseAMLLTTML(raw); ok {
			return r
		}
	}
	return amllResult{}
}
