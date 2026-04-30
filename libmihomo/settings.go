package libmihomo

import (
	"encoding/json"
	"os"

	"github.com/metacubex/mihomo/log"
)

// RuntimeSettings mirrors the on-disk shape of the host app's
// settings.json. The host writes whenever the user toggles a preference;
// the Go core re-reads on every Start / Reload, so changes propagate
// without anyone shuttling values through the extension's IPC.
//
// Field tags must match Library/RuntimeSettings.swift's `Snapshot`.
// Add fields here AND in the Swift type — the JSON is the contract.
type RuntimeSettings struct {
	DisableExternalController bool `json:"disableExternalController"`
	// 0=DEBUG 1=INFO 2=WARNING 3=ERROR 4=SILENT. Defaults to WARNING
	// so a fresh install (no settings.json yet) doesn't flood the log
	// stream with mihomo's debug chatter.
	LogLevel int `json:"logLevel"`
}

func defaultSettings() RuntimeSettings {
	return RuntimeSettings{
		DisableExternalController: false,
		LogLevel:                  int(log.WARNING),
	}
}

var settingsPath atomicString

// SetSettingsPath tells the Go core where the host app's settings.json
// lives. Pass the App Group container path. Calling with "" disables the
// reader — Start / Reload then fall back to defaultSettings().
func SetSettingsPath(path string) {
	settingsPath.Store(path)
}

// loadSettings reads settings.json. A missing file or parse error returns
// defaultSettings() rather than an error: a fresh install must be able to
// Start before the host app has written anything, and a partial / corrupt
// file shouldn't prevent the tunnel from coming up.
func loadSettings() RuntimeSettings {
	s := defaultSettings()
	path := settingsPath.Load()
	if path == "" {
		return s
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return s
	}
	_ = json.Unmarshal(data, &s)
	// Guard the log level so a hand-edited settings.json with an
	// out-of-range value can't desync the runtime filter.
	if s.LogLevel < 0 {
		s.LogLevel = 0
	}
	if s.LogLevel > 4 {
		s.LogLevel = 4
	}
	return s
}
