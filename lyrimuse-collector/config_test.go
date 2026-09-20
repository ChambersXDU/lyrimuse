package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfigSkipsOnlyTheBadField(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	body := `{
	  "listenbrainz_token": "tok",
	  "listenbrainz_user": "someone",
	  "bundle_ids": "com.apple.Music",
	  "bark_url": "https://example.invalid/push"
	}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("坏字段不该让 loadConfig 失败: %v", err)
	}
	if cfg.Token != "tok" || cfg.User != "someone" {
		t.Errorf("好字段被连累了: token=%q user=%q", cfg.Token, cfg.User)
	}
	if cfg.NotificationWebhookURL != "https://example.invalid/push" {
		t.Errorf("坏字段之后的字段也要生效, got %q", cfg.NotificationWebhookURL)
	}

	if len(cfg.BundleIDs) != 1 || cfg.BundleIDs[0] != "com.apple.Music" {
		t.Errorf("bundle_ids 应该回落到默认值, got %v", cfg.BundleIDs)
	}
	if len(cfg.loadIssues) != 1 {
		t.Fatalf("应该正好记下一条问题, got %v", cfg.loadIssues)
	}
	if !strings.Contains(cfg.loadIssues[0], "bundle_ids") {
		t.Errorf("问题描述要点名是哪个字段, got %q", cfg.loadIssues[0])
	}
}

func TestLoadConfigSurvivesBrokenSyntax(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"listenbrainz_token": "tok",`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("语法坏掉也不该失败(否则 KeepAlive 下就是崩溃循环): %v", err)
	}
	if len(cfg.loadIssues) == 0 {
		t.Error("必须留下一条问题说明,否则用户无从知道配置没生效")
	}

	if cfg.APIRoot == "" || len(cfg.BundleIDs) == 0 || cfg.NotificationPlatform == "" {
		t.Errorf("默认值没填: apiRoot=%q bundleIDs=%v platform=%q",
			cfg.APIRoot, cfg.BundleIDs, cfg.NotificationPlatform)
	}
}

func TestLoadConfigIssuesNeverLeakSecrets(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	const secret = "s3cr3t-do-not-log-me"

	body := `{
	  "listenbrainz_token": {"nested": "` + secret + `"},
	  "listenbrainz_user": ["` + secret + `"],
	  "state_relay_token": 12345
	}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.loadIssues) != 3 {
		t.Fatalf("三个字段都该被跳过, got %v", cfg.loadIssues)
	}
	for _, issue := range cfg.loadIssues {
		if strings.Contains(issue, secret) {
			t.Errorf("问题描述泄露了配置值: %q", issue)
		}
	}
}

func TestLoadConfigMissingFileIsNotAnIssue(t *testing.T) {
	cfg, err := loadConfig(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatalf("配置不存在不该报错: %v", err)
	}
	if len(cfg.loadIssues) != 0 {
		t.Errorf("不存在的配置不该产生问题记录, got %v", cfg.loadIssues)
	}
	if cfg.APIRoot != "https://api.listenbrainz.org" {
		t.Errorf("默认 apiRoot 没填, got %q", cfg.APIRoot)
	}
}
