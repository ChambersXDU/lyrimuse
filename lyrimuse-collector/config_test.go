package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfigKeepsUsableFieldsWhenAnUnknownFieldIsPresent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"log_level":"debug","legacy_token":{"nested":"secret"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.LogLevel != "debug" {
		t.Fatalf("log level was not loaded: %q", cfg.LogLevel)
	}
	if len(cfg.loadIssues) != 0 {
		t.Fatalf("unknown legacy fields should be ignored: %v", cfg.loadIssues)
	}
}

func TestLoadConfigSurvivesBrokenSyntax(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"log_level":"info",`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.loadIssues) == 0 || !strings.Contains(cfg.loadIssues[0], "解析失败") {
		t.Fatalf("syntax failure should be reported without aborting: %v", cfg.loadIssues)
	}
}

func TestLoadConfigMissingFileIsAllowed(t *testing.T) {
	cfg, err := loadConfig(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.LogLevel != "" || len(cfg.loadIssues) != 0 {
		t.Fatalf("missing config should use empty defaults: %+v", cfg)
	}
}
