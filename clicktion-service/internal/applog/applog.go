// Package applog writes the service log to a daily file under <dataDir>/logs
// and keeps the last 7 days, pruning older files automatically.
package applog

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const retainDays = 7

// Init points the standard logger at both stderr and a daily rotating file.
func Init(dataDir string) {
	dir := filepath.Join(dataDir, "logs")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("applog: cannot create %s: %v", dir, err)
		return
	}
	w := &dailyWriter{dir: dir}
	log.SetOutput(io.MultiWriter(os.Stderr, w))
	log.Printf("logging to %s (kept %d days)", dir, retainDays)
}

type dailyWriter struct {
	mu  sync.Mutex
	dir string
	day string
	f   *os.File
}

func (w *dailyWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	today := time.Now().Format("2006-01-02")
	if w.f == nil || today != w.day {
		if w.f != nil {
			w.f.Close()
		}
		f, err := os.OpenFile(
			filepath.Join(w.dir, "clicktion-"+today+".log"),
			os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			// Never break the caller's logging on a file error.
			return len(p), nil
		}
		w.f = f
		w.day = today
		w.prune()
	}
	return w.f.Write(p)
}

// prune removes log files older than retainDays.
func (w *dailyWriter) prune() {
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -retainDays)
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasPrefix(name, "clicktion-") || !strings.HasSuffix(name, ".log") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(w.dir, name))
		}
	}
}
