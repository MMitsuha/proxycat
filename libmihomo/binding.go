// Package libmihomo is the gomobile-bind surface used by the iOS app and
// Network Extension. Every exported symbol must use only types gomobile
// supports: primitives, byte slices, strings, error, and named structs of
// those. No interfaces (besides callbacks declared here), no channels, no
// generics across the boundary.
package libmihomo

import (
	"fmt"
	"net/netip"
	"sync"
	"sync/atomic"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

// Virtual TUN addresses installed in fd-mode. They MUST match the
// NEPacketTunnelNetworkSettings configured by PacketTunnelProvider so
// gvisor's netstack recognises incoming packets as locally addressed.
var (
	tunInet4 = netip.MustParsePrefix("198.18.0.1/16")
	tunInet6 = netip.MustParsePrefix("fd00:7f::1/64")
)

var (
	startMu  sync.Mutex
	started  atomic.Bool
	pendingFd int32

	homeDirMu sync.Mutex
	homeDir   string
)

// SetHomeDir tells mihomo where to keep cache.db, downloaded providers, the
// external UI, etc. On iOS the only writable path for the Network Extension
// is the App Group container; pass that here BEFORE Start. Calling after a
// successful Start has no effect on already-loaded files.
func SetHomeDir(path string) {
	homeDirMu.Lock()
	homeDir = path
	homeDirMu.Unlock()
	C.SetHomeDir(path)
}

// Start parses the YAML config and brings the mihomo core up.
// If a TUN file descriptor was previously installed via SetTunFd, the parsed
// config is patched so the TUN inbound uses it instead of opening a kernel
// device (which iOS Network Extensions cannot do). The TUN's device name
// and inet4/inet6 addresses are also cleared because on iOS the host's
// NEPacketTunnelNetworkSettings already owns those values; leaving the YAML
// defaults causes "bad tun name" or IPv6 bind failures.
func Start(yamlConfig []byte) error {
	startMu.Lock()
	defer startMu.Unlock()

	if started.Load() {
		return fmt.Errorf("mihomo already started")
	}

	homeDirMu.Lock()
	hd := homeDir
	homeDirMu.Unlock()
	if hd != "" {
		C.SetHomeDir(hd)
	}

	cfg, err := executor.ParseWithBytes(yamlConfig)
	if err != nil {
		return err
	}

	if fd := atomic.LoadInt32(&pendingFd); fd > 0 {
		// Inject the fd. Force the TUN to look the way iOS expects.
		cfg.General.Tun.Enable = true
		cfg.General.Tun.FileDescriptor = int(fd)
		cfg.General.Tun.Device = "" // don't try to open by name
		// Routing is owned by NEPacketTunnelNetworkSettings on iOS.
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.AutoRedirect = false
		cfg.General.Tun.StrictRoute = false
		// Provide a deterministic virtual address pair so sing-tun's
		// gvisor netstack accepts packets. Must match what
		// PacketTunnelProvider.configureNetworkSettings installs on the
		// host side; otherwise the kernel's utun delivers packets the
		// virtual stack rejects.
		cfg.General.Tun.Inet4Address = []netip.Prefix{tunInet4}
		cfg.General.Tun.Inet6Address = []netip.Prefix{tunInet6}
		// User-supplied route filters from the YAML are usually about
		// kernel routing on Linux/macOS — irrelevant in fd-mode.
		cfg.General.Tun.Inet4RouteAddress = nil
		cfg.General.Tun.Inet6RouteAddress = nil
		cfg.General.Tun.Inet4RouteExcludeAddress = nil
		cfg.General.Tun.Inet6RouteExcludeAddress = nil
		cfg.General.Tun.RouteAddress = nil
		cfg.General.Tun.RouteAddressSet = nil
		cfg.General.Tun.RouteExcludeAddress = nil
		cfg.General.Tun.RouteExcludeAddressSet = nil
	}

	hub.ApplyConfig(cfg)
	started.Store(true)
	return nil
}

// Stop halts mihomo cleanly. Safe to call multiple times.
func Stop() {
	startMu.Lock()
	defer startMu.Unlock()

	if !started.Load() {
		return
	}
	executor.Shutdown()
	started.Store(false)
}

// IsRunning reports whether the core is currently up.
func IsRunning() bool {
	return started.Load()
}

// SetTunFd installs a TUN file descriptor obtained from
// NEPacketTunnelProvider. Must be called before Start. Pass 0 to clear.
//
// On iOS the fd ownership belongs to the kernel-supplied utun socket; we
// don't dup or close it here.
func SetTunFd(fd int) error {
	atomic.StoreInt32(&pendingFd, int32(fd))
	return nil
}

// SetLogLevel changes runtime log filter. Levels: 0=DEBUG 1=INFO 2=WARNING 3=ERROR 4=SILENT.
func SetLogLevel(level int) {
	if level < 0 {
		level = 0
	}
	if level > 4 {
		level = 4
	}
	log.SetLevel(log.LogLevel(level))
}

// LogLevel returns the current log level.
func LogLevel() int {
	return int(log.Level())
}
