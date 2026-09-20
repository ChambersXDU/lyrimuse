package main

import (
	"os"
	"path/filepath"
)

func configDir() string {
	if v := os.Getenv("LYRIMUSE_CONFIG_DIR"); v != "" && filepath.IsAbs(v) {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", clientName)
}

func configFilePath(name string) string {
	return filepath.Join(configDir(), name)
}

func appBundleID() string {
	if v := os.Getenv("LYRIMUSE_APP_BUNDLE_ID"); v != "" {
		return v
	}
	return "me.yudaotor.lyrimuse"
}

func logFilePath() string {
	if v := os.Getenv("LYRIMUSE_LOG_FILE"); v != "" && filepath.IsAbs(v) {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Logs", clientName+".log")
}
