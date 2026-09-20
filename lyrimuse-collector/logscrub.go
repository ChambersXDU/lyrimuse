package main

import (
	"io"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

const redactedMark = "***"

const (
	minSecretLen = 8
)

var (
	secretsMu     sync.Mutex
	knownSecrets  []string
	secretReplace atomic.Pointer[strings.Replacer]
)

var sensitiveQueryRe = regexp.MustCompile(
	`(?i)([?&](?:sk|[a-z0-9_.\-]*(?:key|token|secret|sig|sign|password|passwd|pwd|auth)[a-z0-9_.\-]*)=)[^&\s"'` + "`" + `]+`)

func registerSecrets(values ...string) {
	registerSecretsMinLen(minSecretLen, values...)
}

func registerSecretsMinLen(minLen int, values ...string) {
	secretsMu.Lock()
	defer secretsMu.Unlock()
	added := false
	for _, v := range values {
		v = strings.TrimSpace(v)
		if len(v) < minLen || slices.Contains(knownSecrets, v) {
			continue
		}
		knownSecrets = append(knownSecrets, v)
		added = true
	}
	if !added {
		return
	}

	sorted := slices.Clone(knownSecrets)
	sort.SliceStable(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
	pairs := make([]string, 0, len(sorted)*2)
	for _, v := range sorted {
		pairs = append(pairs, v, redactedMark)
	}
	secretReplace.Store(strings.NewReplacer(pairs...))
}

func scrubSecrets(s string) string {
	if r := secretReplace.Load(); r != nil {
		s = r.Replace(s)
	}
	return sensitiveQueryRe.ReplaceAllString(s, "${1}"+redactedMark)
}

type secretScrubber struct{ w io.Writer }

func (s secretScrubber) Write(p []byte) (int, error) {
	cleaned := scrubSecrets(string(p))
	if cleaned == string(p) {
		return s.w.Write(p)
	}
	if _, err := s.w.Write([]byte(cleaned)); err != nil {
		return 0, err
	}

	return len(p), nil
}
