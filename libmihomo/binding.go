// Package libmihomo is the gomobile-bind surface used by the iOS app and
// Network Extension. Every exported symbol must use only types gomobile
// supports: primitives, byte slices, strings, error, and named structs of
// those. No interfaces (besides callbacks declared here), no channels, no
// generics across the boundary.
package libmihomo

import (
	"fmt"
	"net/netip"
	"runtime"
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

	socketPathMu sync.Mutex
	socketPath   string
)

// SetCommandSocketPath chooses where the gRPC command server listens.
// Must point at a path inside an App Group container so the host app
// can connect. Pass "" to disable the server. Call before Start.
func SetCommandSocketPath(path string) {
	socketPathMu.Lock()
	socketPath = path
	socketPathMu.Unlock()
}

func commandSocketPath() string {
	socketPathMu.Lock()
	defer socketPathMu.Unlock()
	return socketPath
}

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
		// gVisor netstack is the only stack that works inside the iOS
		// Network Extension sandbox. The "System" stack tries to make
		// real kernel-level socket calls that the NE entitlement doesn't
		// permit and silently drops responses.
		cfg.General.Tun.Stack = C.TunGvisor
		// Routing is owned by NEPacketTunnelNetworkSettings on iOS, and
		// AutoDetectInterface picks the TUN itself (since utun is the
		// default route once NE is up) which loops DIRECT outbound back
		// onto the tunnel.
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.AutoRedirect = false
		cfg.General.Tun.StrictRoute = false
		// Same reason: don't let mihomo bind DIRECT outbound sockets to
		// any interface — iOS NE already exempts the extension's own
		// sockets from the tunnel it provides.
		cfg.General.Interface = ""
		cfg.General.RoutingMark = 0
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
	startOOMKiller()
	if path := commandSocketPath(); path != "" {
		if err := StartCommandServer(path); err != nil {
			log.Warnln("[command] start server: %v", err)
		}
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
	StopCommandServer()
	stopOOMKiller()
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

// Validate parses the YAML and reports the first parse / semantic error,
// without applying anything. Returns nil when the config is acceptable.
//
// Mihomo's parser is lenient — it tolerates unknown keys and fills in
// missing fields with defaults — so a successful Validate doesn't promise
// the proxy will actually connect, only that the file is loadable.
func Validate(yamlConfig []byte) error {
	if len(yamlConfig) == 0 {
		return fmt.Errorf("config is empty")
	}
	_, err := executor.ParseWithBytes(yamlConfig)
	return err
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

// Wrapper-level build identifiers. Populated by `go build -ldflags -X` at
// xcframework build time (see scripts/build-libmihomo.sh). Empty when
// running tests / `go run` without the script.
var (
	wrapperBuildTime = "unknown"
	wrapperBuildTag  = "with_gvisor"
	mihomoCommit     = "unknown"
)

// VersionInfo holds build-time identifying information about the embedded
// mihomo core and its Go runtime. Reported on the Settings → Diagnostics
// screen so users can attach it to bug reports.
type VersionInfo struct {
	// Mihomo's semantic version (constant.Version, e.g. "1.10.0").
	Mihomo string
	// constant.BuildTime — set by the mihomo build, "unknown time"
	// when built from a plain `go build`.
	MihomoBuildTime string
	// Mihomo upstream commit hash, captured by the build script from
	// the local mihomo checkout.
	MihomoCommit string
	// Time the xcframework itself was assembled.
	WrapperBuildTime string
	// Build tags used when compiling (e.g. "with_gvisor").
	BuildTags string
	// Go runtime / compiler version, e.g. "go1.26.2".
	Go string
	// GOOS/GOARCH the Go runtime was built for.
	Platform string
	// Whether mihomo's "Meta" extensions (constant.Meta) are compiled
	// in. Always true for our builds; surfaced for completeness.
	Meta bool
}

// Version returns build identification for the embedded core.
func Version() *VersionInfo {
	return &VersionInfo{
		Mihomo:           C.Version,
		MihomoBuildTime:  C.BuildTime,
		MihomoCommit:     mihomoCommit,
		WrapperBuildTime: wrapperBuildTime,
		BuildTags:        wrapperBuildTag,
		Go:               runtime.Version(),
		Platform:         runtime.GOOS + "/" + runtime.GOARCH,
		Meta:             C.Meta,
	}
}
