package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"reflect"
	"strings"
	"sync"
)

type enrichEntryPlain enrichEntry

var (
	enrichEntryKnownKeysOnce sync.Once
	enrichEntryKnownKeys     map[string]bool
)

func enrichEntryKnownJSONKeys() map[string]bool {
	enrichEntryKnownKeysOnce.Do(func() {
		keys := map[string]bool{}
		t := reflect.TypeOf(enrichEntryPlain{})
		for i := 0; i < t.NumField(); i++ {
			tag := t.Field(i).Tag.Get("json")
			name := strings.Split(tag, ",")[0]
			if name == "" || name == "-" {
				continue
			}
			keys[name] = true
		}
		enrichEntryKnownKeys = keys
	})
	return enrichEntryKnownKeys
}

func (e *enrichEntry) UnmarshalJSON(b []byte) error {
	var p enrichEntryPlain
	strict := json.NewDecoder(bytes.NewReader(b))
	strict.DisallowUnknownFields()
	err := strict.Decode(&p)
	if err == nil {
		*e = enrichEntry(p)
		return nil
	}
	if !strings.Contains(err.Error(), "unknown field") {
		return err
	}

	p = enrichEntryPlain{}
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	known := enrichEntryKnownJSONKeys()
	for k, v := range raw {
		if known[k] {
			continue
		}
		if p.Unknown == nil {
			p.Unknown = map[string]json.RawMessage{}
		}
		p.Unknown[k] = v
	}
	*e = enrichEntry(p)
	return nil
}

func (e enrichEntry) MarshalJSON() ([]byte, error) {
	b, err := json.Marshal(enrichEntryPlain(e))
	if err != nil || len(e.Unknown) == 0 {
		return b, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	for k, v := range e.Unknown {
		if _, taken := m[k]; taken {
			continue
		}
		m[k] = v
	}
	return json.Marshal(m)
}

func enrichEntriesWithUnknownKeys(m map[string]enrichEntry) int {
	n := 0
	for _, e := range m {
		if len(e.Unknown) > 0 {
			n++
		}
	}
	return n
}

func warnEnrichUnknownKeys(m map[string]enrichEntry) {
	if n := enrichEntriesWithUnknownKeys(m); n > 0 {
		slog.Warn("enrich cache: entries carry fields this build does not know, preserving them verbatim (older build than the cache file?)", "entries", n)
	}
}
