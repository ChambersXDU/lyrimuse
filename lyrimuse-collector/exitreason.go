package main

import (
	"fmt"
	"log"
	"os"
)

const (

	exitReasonAlreadyRunning = "already_running"

	exitReasonSignal = "signal"

	exitReasonRunError = "run_error"

	exitReasonConfigUnreadable  = "config_unreadable"
	exitReasonHomeDirUnresolved = "home_dir_unresolved"

	exitReasonRunReturned = "run_returned"
)

func logExit(reason string, detail string) {
	if detail == "" {
		log.Printf("exiting reason=%s", reason)
	} else {
		log.Printf("exiting reason=%s %s", reason, detail)
	}

	flushLogSink()
}

func fatalExit(reason string, format string, args ...any) {
	logExit(reason, fmt.Sprintf(format, args...))
	os.Exit(1)
}
