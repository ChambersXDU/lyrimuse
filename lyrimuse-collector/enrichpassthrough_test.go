package main

import (
	"encoding/json"
	"testing"
)

func TestEnrichEntryPreservesAppOwnedFields(t *testing.T) {

	probes := map[string]string{
		"manual_pick_sha":      "deadbeef1234",
		"lyrics_source_choice": "netease",
	}
	entry := map[string]any{"lyrics": "[00:01.00]x\n"}
	for k, v := range probes {
		entry[k] = v
	}
	raw, err := json.Marshal(map[string]any{"a|b|c": entry})
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}

	var m map[string]enrichEntry
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	var back map[string]map[string]any
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("unmarshal round-tripped: %v", err)
	}

	for field, want := range probes {
		got, ok := back["a|b|c"][field]
		if !ok {
			t.Errorf("字段 %q 在一次 collector 往返后消失了 —— enrichEntry 里没有声明它，"+
				"App 侧写进去的值会被下一次存盘静默抹掉", field)
			continue
		}
		if got != want {
			t.Errorf("字段 %q 往返后变了: got %v, want %v", field, got, want)
		}
	}
}
