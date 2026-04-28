// Package libmihomo is the gomobile-bind surface used by the iOS app and
// Network Extension. Every exported symbol must use only types gomobile
// supports: primitives, byte slices, strings, error, and named structs of
// those. No interfaces (besides callbacks declared here), no channels, no
// generics across the boundary.
package libmihomo

import (
	"fmt"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	startMu  sync.Mutex
	started  atomic.Bool
	pendingFd int32
)

// Start parses the YAML config and brings the mihomo core up.
// If a TUN file descriptor was previously installed via SetTunFd, the parsed
// config is patched so the TUN inbound uses it instead of opening a kernel
// device (which iOS Network Extensions cannot do).
func Start(yamlConfig []byte) error {
	startMu.Lock()
	defer startMu.Unlock()

	if started.Load() {
		return fmt.Errorf("mihomo already started")
	}

	if err := hub.Parse(yamlConfig); err != nil {
		return err
	}

	if fd := atomic.LoadInt32(&pendingFd); fd > 0 {
		conf := listener.GetTunConf()
		conf.Enable = true
		conf.FileDescriptor = int(fd)
		listener.ReCreateTun(conf, tunnel.Tunnel)
	}

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
// NEPacketTunnelProvider. Call before Start, or while running to swap.
// Pass 0 to clear.
func SetTunFd(fd int) error {
	atomic.StoreInt32(&pendingFd, int32(fd))
	if !started.Load() {
		return nil
	}
	conf := listener.GetTunConf()
	conf.FileDescriptor = fd
	conf.Enable = fd > 0
	listener.ReCreateTun(conf, tunnel.Tunnel)
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
