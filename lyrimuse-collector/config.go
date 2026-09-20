package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

type config struct {
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
