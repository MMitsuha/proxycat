package libmihomo

import (
	"os"
	"path/filepath"
	"testing"
)

func TestActiveLogMarkerRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mihomo-test.log")

	writeActiveLogMarker(dir, path)

	data, err := os.ReadFile(activeLogMarkerPath(dir))
	if err != nil {
		t.Fatalf("read active marker: %v", err)
	}
	if got, want := string(data), path+"\n"; got != want {
		t.Fatalf("active marker = %q, want %q", got, want)
	}

	removeActiveLogMarker(dir, path)

	if _, err := os.Stat(activeLogMarkerPath(dir)); !os.IsNotExist(err) {
		t.Fatalf("active marker still exists after remove: %v", err)
	}
}

func TestRemoveActiveLogMarkerKeepsDifferentSession(t *testing.T) {
	dir := t.TempDir()
	activePath := filepath.Join(dir, "mihomo-active.log")
	stalePath := filepath.Join(dir, "mihomo-stale.log")

	writeActiveLogMarker(dir, activePath)
	removeActiveLogMarker(dir, stalePath)

	data, err := os.ReadFile(activeLogMarkerPath(dir))
	if err != nil {
		t.Fatalf("read active marker: %v", err)
	}
	if got, want := string(data), activePath+"\n"; got != want {
		t.Fatalf("active marker = %q, want %q", got, want)
	}
}
