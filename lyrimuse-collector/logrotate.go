package main

import (
	"io"
	"os"
)

const logRotateMaxBytes int64 = 30 * 1024 * 1024

func rotateLogIfNeeded(path string, maxBytes int64) (io.Writer, bool) {
	fallback := io.Writer(os.Stderr)
	if path == "" {
		return fallback, false
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() < maxBytes {
		return fallback, false
	}

	f, ok := archiveAndReopen(path)
	if !ok {
		return fallback, false
	}
	return f, true
}

func archiveAndReopen(path string) (*os.File, bool) {
	oldPath := path + ".old"
	_ = os.Remove(oldPath)
	if err := os.Rename(path, oldPath); err != nil {
		return nil, false
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {

		_ = os.Rename(oldPath, path)
		return nil, false
	}
	return f, true
}
