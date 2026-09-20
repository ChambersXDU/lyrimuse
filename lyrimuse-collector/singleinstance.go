package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
)

var singleInstanceLockFile *os.File

func acquireSingleInstanceLock(dir string) bool {
	path := filepath.Join(dir, "collector.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		log.Printf("single-instance lock unavailable (%v), continuing without it", err)
		return true
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return false
	}

	singleInstanceLockFile = f
	_ = f.Truncate(0)
	_, _ = fmt.Fprintf(f, "%d\n", os.Getpid())
	return true
}
