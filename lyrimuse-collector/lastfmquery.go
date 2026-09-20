package main

import (
	neturl "net/url"
	"sort"
	"strings"
)

func lastfmGetQuery(q neturl.Values) string {
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}

	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		for _, v := range q[k] {
			if b.Len() > 0 {
				b.WriteByte('&')
			}
			b.WriteString(lastfmEscape(k))
			b.WriteByte('=')
			b.WriteString(lastfmEscape(v))
		}
	}
	return b.String()
}

func lastfmEscape(s string) string {
	doubled := strings.ReplaceAll(s, "%", "%25")
	doubled = strings.ReplaceAll(doubled, "+", "%2B")
	return strings.ReplaceAll(neturl.QueryEscape(doubled), "+", "%20")
}
