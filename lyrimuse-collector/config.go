package main

import (
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"os"
)

type config struct {
	Token     string   `json:"listenbrainz_token"`
	User      string   `json:"listenbrainz_user,omitempty"`
	APIRoot   string   `json:"api_root,omitempty"`
	BundleIDs []string `json:"bundle_ids,omitempty"`

	StateRelayURL   string `json:"state_relay_url,omitempty"`
	StateRelayToken string `json:"state_relay_token,omitempty"`

	NotificationPlatform   string `json:"notification_platform,omitempty"`
	NotificationWebhookURL string `json:"bark_url,omitempty"`

	DingtalkSignSecret string `json:"dingtalk_sign_secret,omitempty"`
	FeishuSignSecret   string `json:"feishu_sign_secret,omitempty"`

	LogLevel string `json:"log_level,omitempty"`

	loadIssues []string
}

func loadConfig(path string) (*config, error) {
	cfg := &config{}
	data, err := os.ReadFile(path)
	if err == nil {
		cfg.loadIssues = decodeConfigPerField(data, cfg)
	} else if !errors.Is(err, os.ErrNotExist) {

		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	if v := os.Getenv("LISTENBRAINZ_TOKEN"); v != "" {
		cfg.Token = v
	}
	if cfg.APIRoot == "" {
		cfg.APIRoot = "https://api.listenbrainz.org"
	}
	if len(cfg.BundleIDs) == 0 {
		cfg.BundleIDs = []string{"com.apple.Music"}
	}
	if cfg.NotificationPlatform == "" {

		cfg.NotificationPlatform = "bark"
	}

	rememberConfigSecrets(cfg)
	return cfg, nil
}

func decodeConfigPerField(data []byte, cfg *config) []string {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {

		return []string{fmt.Sprintf("整个配置文件解析失败(%v),本次按默认值运行", err)}
	}
	var issues []string
	for key, rawVal := range raw {
		single, err := json.Marshal(map[string]json.RawMessage{key: rawVal})
		if err != nil {
			issues = append(issues, fmt.Sprintf("%q: %v", key, err))
			continue
		}
		probe := *cfg
		if err := json.Unmarshal(single, &probe); err != nil {
			issues = append(issues, fmt.Sprintf("%q 格式不对,已跳过(%v)", key, err))
			continue
		}
		*cfg = probe
	}
	return issues
}
