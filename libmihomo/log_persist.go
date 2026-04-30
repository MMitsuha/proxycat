package libmihomo

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/metacubex/mihomo/log"
)

// Log persistence: every time the tunnel comes up the host app calls
// StartLogFile, which subscribes to mihomo's log observable and copies
// every event to a fresh timestamped file in the configured directory.
// The host app then lists / displays / deletes these files from its UI.
//
// Subscribing here is independent of the gRPC SubscribeLogs in
// command_server.go, so the streaming Log tab and the on-disk log file
// receive the same events without affecting each other.

type logFileSession struct {
	path string
	file *os.File
	pump *logPump
}

var (
	logFileDir     atomicString
	sessionMu      sync.Mutex
	currentSession *logFileSession
)

// SetLogFileDir tells the persist layer where to drop session log files.
// On iOS this should be a path inside the App Group container so the
// host app can also read the files. Pass "" to clear. Must be called
// before StartLogFile.
func SetLogFileDir(path string) {
	logFileDir.Store(path)
}

// StartLogFile opens a new timestamped log file in the configured
// directory and begins copying every mihomo log event into it. Returns
// the absolute path of the file. Idempotent: a second call while a
// session is already active returns the existing path without rotating.
//
// Filenames look like `mihomo-20260428-153045.log`. If a same-second
// reconnect happens, a `-N` suffix is appended so each session keeps
// its own file.
func StartLogFile() (string, error) {
	sessionMu.Lock()
	if currentSession != nil {
		path := currentSession.path
		sessionMu.Unlock()
		return path, nil
	}
	sessionMu.Unlock()

	dir := logFileDir.Load()
	if dir == "" {
		return "", fmt.Errorf("log file directory not set")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	base := fmt.Sprintf("mihomo-%s", time.Now().Format("20060102-150405"))
	var (
		path string
		f    *os.File
		err  error
	)
	for i := range 100 {
		name := base
		if i > 0 {
			name = fmt.Sprintf("%s-%d", base, i)
		}
		path = filepath.Join(dir, name+".log")
		f, err = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o644)
		if err == nil {
			break
		}
		if !os.IsExist(err) {
			return "", err
		}
		f = nil
	}
	if f == nil {
		return "", fmt.Errorf("could not create log file in %s", dir)
	}

	// Claim ownership before subscribing to the log observable: if a
	// racing StartLogFile won between our two locks, roll back the file
	// without ever creating a stray subscription.
	sessionMu.Lock()
	if currentSession != nil {
		existing := currentSession.path
		sessionMu.Unlock()
		_ = f.Close()
		_ = os.Remove(path)
		return existing, nil
	}

	s := &logFileSession{path: path, file: f}
	header := fmt.Sprintf("=== mihomo session started %s ===\n",
		time.Now().Format(time.RFC3339))
	_, _ = f.WriteString(header)

	// Start the pump while still holding sessionMu so currentSession is
	// never observed with a nil pump. log.Subscribe is essentially free
	// (a slice append behind a mutex inside mihomo); the goroutine
	// itself starts non-blocking.
	s.pump = startLogPump(func(event log.Event) {
		line := fmt.Sprintf(
			"%s [%s] %s\n",
			time.Now().Format("2006-01-02T15:04:05.000"),
			event.LogLevel.String(),
			event.Payload,
		)
		_, _ = s.file.WriteString(line)
	})
	currentSession = s
	sessionMu.Unlock()

	return path, nil
}

// StopLogFile flushes and closes the active log file. Safe to call
// multiple times; also called automatically from Stop() so the file
// always closes cleanly even if the host app forgets.
func StopLogFile() {
	sessionMu.Lock()
	s := currentSession
	currentSession = nil
	sessionMu.Unlock()
	if s == nil {
		return
	}
	s.pump.Close()
	_, _ = fmt.Fprintf(s.file, "=== mihomo session ended %s ===\n",
		time.Now().Format(time.RFC3339))
	_ = s.file.Sync()
	_ = s.file.Close()
}

// CurrentLogFilePath returns the path of the active log file, or "" if
// no session is currently being persisted. Surfaced so the host app's
// "Saved Logs" UI can highlight the in-progress file.
func CurrentLogFilePath() string {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if currentSession == nil {
		return ""
	}
	return currentSession.path
}
