package main

import (
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

const logTimeLayout = "2006-01-02T15:04:05.000Z"

var logLevel = new(slog.LevelVar)

func parseLogLevel(s string) (slog.Level, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug, true
	case "", "info":
		return slog.LevelInfo, true
	case "warn", "warning":
		return slog.LevelWarn, true
	case "error":
		return slog.LevelError, true
	}
	return slog.LevelInfo, false
}

func applyLogLevel(configured string) {
	if env := os.Getenv("LYRIMUSE_LOG_LEVEL"); env != "" {
		if lv, ok := parseLogLevel(env); ok {
			logLevel.Set(lv)
			return
		}
		log.Printf("log: unrecognized LYRIMUSE_LOG_LEVEL %q, falling back to config", env)
	}
	lv, ok := parseLogLevel(configured)
	if !ok {
		log.Printf("log: unrecognized log_level %q in config, keeping %s", configured, logLevel.Level())
		return
	}
	logLevel.Set(lv)
}

func newLogHandler(w io.Writer) slog.Handler {
	return slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: logLevel,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				if t, ok := a.Value.Any().(time.Time); ok {
					return slog.String(slog.TimeKey, t.UTC().Format(logTimeLayout))
				}
			}
			return a
		},
	})
}

func isDaemonInvocation(args []string) bool {
	return len(args) < 2 || strings.HasPrefix(args[1], "-")
}

const repeatSquelchWindow = 60 * time.Second

var (
	logTimeAttrRe = regexp.MustCompile(`^time=\S+ `)
	logDigitsRe   = regexp.MustCompile(`\d+`)
)

func lineTemplate(line string) string {
	line = logTimeAttrRe.ReplaceAllString(line, "")
	return logDigitsRe.ReplaceAllString(line, "#")
}

type repeatSquelcher struct {
	mu           sync.Mutex
	w            io.Writer
	lastTemplate string
	lastAt       time.Time
	repeats      int
	now          func() time.Time
}

func newRepeatSquelcher(w io.Writer) *repeatSquelcher {
	return &repeatSquelcher{w: w, now: time.Now}
}

func (s *repeatSquelcher) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	tmpl := lineTemplate(string(p))
	if tmpl == s.lastTemplate && now.Sub(s.lastAt) <= repeatSquelchWindow {
		s.repeats++
		s.lastAt = now

		return len(p), nil
	}
	if err := s.flushLocked(now); err != nil {
		return 0, err
	}
	s.lastTemplate = tmpl
	s.lastAt = now
	return s.w.Write(p)
}

func (s *repeatSquelcher) flushLocked(now time.Time) error {
	if s.repeats == 0 {
		return nil
	}
	n := s.repeats
	s.repeats = 0
	_, err := fmt.Fprintf(s.w, "time=%s level=INFO msg=\"last message repeated %d times\"\n",
		now.UTC().Format(logTimeLayout), n)
	return err
}

func (s *repeatSquelcher) Flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.repeats > 0 && now.Sub(s.lastAt) <= repeatSquelchWindow {

		return
	}
	_ = s.flushLocked(now)
	s.lastTemplate = ""
}

func (s *repeatSquelcher) flushNow() {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.flushLocked(s.now())
	s.lastTemplate = ""
}

type rotatingLogFile struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	f        *os.File
	size     int64

	rotatedAtOpen bool
}

func openRotatingLogFile(path string, maxBytes int64) *rotatingLogFile {
	if path == "" {
		return nil
	}
	w, rotated := rotateLogIfNeeded(path, maxBytes)
	f, ok := w.(*os.File)
	if !ok || f == os.Stderr {

		opened, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return nil
		}
		f = opened
	}
	r := &rotatingLogFile{path: path, maxBytes: maxBytes, f: f, rotatedAtOpen: rotated}
	if info, err := f.Stat(); err == nil {
		r.size = info.Size()
	}
	return r
}

func (r *rotatingLogFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.size > 0 && r.size+int64(len(p)) > r.maxBytes {
		r.rotateLocked()
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

func (r *rotatingLogFile) rotateLocked() {
	newF, ok := archiveAndReopen(r.path)
	if !ok {
		return
	}
	_ = r.f.Close()
	r.f = newF
	r.size = 0
	line := fmt.Sprintf("time=%s level=INFO msg=\"log: rotated, previous file exceeded %dMB, archived to lyrimuse.log.old\"\n",
		time.Now().UTC().Format(logTimeLayout), r.maxBytes/1024/1024)
	n, _ := r.f.WriteString(line)
	r.size += int64(n)
}

var logSink struct {
	squelch *repeatSquelcher
	file    *rotatingLogFile
}

func installLogSink(daemon bool) {
	var base io.Writer = os.Stderr
	if daemon {
		if f := openRotatingLogFile(logFilePath(), logRotateMaxBytes); f != nil {
			base = f
			logSink.file = f
		}
	}
	sq := newRepeatSquelcher(secretScrubber{w: base})
	logSink.squelch = sq
	slog.SetDefault(slog.New(newLogHandler(sq)))
	if logSink.file != nil && logSink.file.rotatedAtOpen {
		log.Printf("log: rotated at startup, previous file exceeded %dMB, archived to lyrimuse.log.old",
			logRotateMaxBytes/1024/1024)
	}
	stopLogSinkMaintenance()
	if daemon {
		logSinkStopMu.Lock()
		stopCh := make(chan struct{})
		logSinkStopCh = stopCh
		logSinkStopMu.Unlock()
		go logSinkMaintenanceLoop(stopCh)
	}
}

var (
	logSinkStopMu sync.Mutex
	logSinkStopCh chan struct{}
)

func stopLogSinkMaintenance() {
	logSinkStopMu.Lock()
	defer logSinkStopMu.Unlock()
	if logSinkStopCh != nil {
		close(logSinkStopCh)
		logSinkStopCh = nil
	}
}

func logSinkMaintenanceLoop(stopCh <-chan struct{}) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stopCh:
			return
		case <-t.C:
			flushAPICallSummaries(time.Now(), false)
			if logSink.squelch != nil {
				logSink.squelch.Flush()
			}
		}
	}
}

func flushLogSink() {
	stopLogSinkMaintenance()
	flushAPICallSummaries(time.Now(), true)
	if logSink.squelch != nil {
		logSink.squelch.flushNow()
	}
}
