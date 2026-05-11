package libmihomo

import (
	"encoding/json"
	"os"

	"github.com/metacubex/mihomo/log"
)

// RuntimeSettings mirrors the on-disk shape of the host app's
// runtime_settings.json. The host writes whenever the user toggles a
// preference or changes the active profile; the Go core re-reads on every
// Start / Reload, so changes propagate without anyone shuttling values
// through the extension's IPC.
//
// Field tags must match Library/RuntimeSettings.swift's `Snapshot`. Add
// fields here AND in the Swift type — the JSON is the contract.
type RuntimeSettings struct {
	// UUID string of the currently selected profile. Empty on a fresh
	// install (no profile picked yet); Start returns a "no profile
	// selected" error in that case so the host UI can prompt the user.
	ActiveProfileID           string `json:"activeProfileID"`
	DisableExternalController bool   `json:"disableExternalController"`
	// Host-local Logs-view filter. Parsed for JSON compatibility with
	// Library/RuntimeSettings.swift, but intentionally not applied to
	// mihomo's Go logger; the extension persists and streams all events.
	LogLevel int `json:"logLevel"`
}

func defaultSettings() RuntimeSettings {
	return RuntimeSettings{
		DisableExternalController: false,
		LogLevel:                  int(log.WARNING),
	}
}

var settingsPath atomicString

// SetRuntimeSettingsPath tells the Go core where the host app's
// runtime_settings.json lives. Pass the App Group container path. Calling
// with "" disables the reader — Start / Reload then fall back to
// defaultSettings() and an empty active profile (Start fails fast).
func SetRuntimeSettingsPath(path string) {
	settingsPath.Store(path)
}

// loadSettings reads runtime_settings.json. A missing file or parse error
// returns defaultSettings() rather than an error: a fresh install must be
// able to call Start before the host app has written anything, and a
// partial / corrupt file shouldn't prevent the tunnel from coming up
// (Start fails later with a more specific "no active profile" error if
// the active id is empty).
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
	// Guard the host-local UI filter so hand-edited JSON stays inside the
	// Swift LogLevel enum's raw-value range.
	if s.LogLevel < 0 {
		s.LogLevel = 0
	}
	if s.LogLevel > 4 {
		s.LogLevel = 4
	}
	return s
}
