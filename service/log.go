//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// logger is a tiny append-only log with size based rotation. The service does
// not write much, so a full logging package would be overkill.
type logger struct {
	mu   sync.Mutex
	file *os.File
}

func newLogger(dir string) (*logger, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}

	file, err := openLog(filepath.Join(dir, "service.log"), 5<<20)
	if err != nil {
		return nil, err
	}

	return &logger{file: file}, nil
}

func (l *logger) Printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()

	line := fmt.Sprintf(format, args...)
	fmt.Fprintf(l.file, "%s %s\n", time.Now().Format(time.RFC3339), line)
}

func (l *logger) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()

	_ = l.file.Close()
}

// openLog opens path for appending and renames it first when it grew past
// limit. Renaming while the old handle is open is fine on Windows only after
// the handle is closed, so this runs at startup, not mid-write.
func openLog(path string, limit int64) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > limit {
		_ = os.Rename(path, path+".1")
	}

	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}
