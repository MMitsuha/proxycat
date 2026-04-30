// Package libmihomo is the gomobile-bind surface used by the iOS app and
// Network Extension. Every exported symbol must use only types gomobile
// supports: primitives, byte slices, strings, error, and named structs of
// those. No interfaces (besides callbacks declared here), no channels, no
// generics across the boundary.
//
// Design note: this wrapper owns ALL runtime state. The host app and the
// extension only tell us where the App-Group container lives (via the
// Set*Path setters); we read profile YAML, runtime settings, and the
// active-profile pointer ourselves. The Network Extension is intentionally
// a thin shim — every Start / Reload re-reads everything fresh from disk
// so a setting toggled in the host UI takes effect on the next Reload
// without anyone shuttling values through NEPacketTunnelProvider's option
// dictionary or sendProviderMessage payloads.
package libmihomo

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/config"
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
	startMu   sync.Mutex
	started   atomic.Bool
	pendingFd int32

	homeDir       atomicString
	socketPath    atomicString
	activePointer atomicString
	profilesDir   atomicString

	// runtimeLogLevel is the wrapper's source of truth for the mihomo
	// log filter. Initialised to WARNING (2) so YAML profiles that ship
	// with `log-level: debug` or `info` don't flood the host app's log
	// stream by default. SetLogLevel updates this atomically; every
	// Start / Reload re-applies it on top of the parsed config so the
	// YAML's own `log-level:` is always ignored. Reload also re-reads
	// settings.json into this field so the host app can change the
	// runtime level just by writing the JSON.
	runtimeLogLevel atomic.Int32
)

func init() {
	runtimeLogLevel.Store(int32(log.WARNING))
	log.SetLevel(log.WARNING)
}

// SetCommandSocketPath chooses where the gRPC command server listens.
// Must point at a path inside an App Group container so the host app
// can connect. Pass "" to disable the server. Call before Start.
func SetCommandSocketPath(path string) {
	socketPath.Store(path)
}

// SetHomeDir tells mihomo where to keep cache.db, downloaded providers, the
// external UI, etc. On iOS the only writable path for the Network Extension
// is the App Group container; pass that here BEFORE Start. Calling after a
// successful Start has no effect on already-loaded files.
func SetHomeDir(path string) {
	homeDir.Store(path)
	C.SetHomeDir(path)
}

// SetActiveProfilePointer tells the wrapper where the host app's
// `active-profile` UUID file lives. Combined with SetProfilesDir this
// lets Start / Reload load the active profile YAML themselves so the
// extension never has to read or forward it.
func SetActiveProfilePointer(path string) {
	activePointer.Store(path)
}

// SetProfilesDir tells the wrapper where the host app's `Profiles/`
// directory lives (containing `index.json` plus one YAML per profile).
// Combined with SetActiveProfilePointer this lets Start / Reload load
// the active profile YAML on demand.
func SetProfilesDir(path string) {
	profilesDir.Store(path)
}

// profileEntry is the subset of Library/Profile.swift's `Profile` shape
// needed to resolve an active UUID to its YAML filename. Extra fields in
// the JSON are ignored by encoding/json so the host can keep evolving
// the schema without breaking us.
type profileEntry struct {
	ID       string `json:"id"`
	FileName string `json:"fileName"`
}

// loadActiveYAML walks the same disk layout the host app's
// `ProfileStore.loadActiveContentFromDisk` does: read the active-profile
// UUID, look it up in the Profiles index, return the YAML bytes.
//
// Errors are returned verbatim to the caller (Start / Reload). The
// extension surfaces them as the `reload` reply payload so the host UI
// can show a precise message instead of "reload failed".
func loadActiveYAML() ([]byte, error) {
	pointer := activePointer.Load()
	dir := profilesDir.Load()

	if pointer == "" || dir == "" {
		return nil, fmt.Errorf("profile paths not configured (call SetActiveProfilePointer + SetProfilesDir)")
	}

	raw, err := os.ReadFile(pointer)
	if err != nil {
		return nil, fmt.Errorf("read active-profile pointer: %w", err)
	}
	id := strings.TrimSpace(string(raw))
	if id == "" {
		return nil, fmt.Errorf("active-profile pointer is empty")
	}

	indexPath := filepath.Join(dir, "index.json")
	indexRaw, err := os.ReadFile(indexPath)
	if err != nil {
		return nil, fmt.Errorf("read profile index: %w", err)
	}
	var entries []profileEntry
	if err := json.Unmarshal(indexRaw, &entries); err != nil {
		return nil, fmt.Errorf("parse profile index: %w", err)
	}
	for _, e := range entries {
		if e.ID == id {
			yamlPath := filepath.Join(dir, e.FileName)
			data, err := os.ReadFile(yamlPath)
			if err != nil {
				return nil, fmt.Errorf("read profile yaml %s: %w", e.FileName, err)
			}
			return data, nil
		}
	}
	return nil, fmt.Errorf("active profile %s not found in index", id)
}

// Start brings the mihomo core up using the active profile YAML and
// runtime settings the host app has already written into the App-Group
// container. Required setup before this call: SetHomeDir,
// SetCommandSocketPath, SetSettingsPath, SetActiveProfilePointer,
// SetProfilesDir, SetTunFd. SetMemoryLimit is optional but recommended.
//
// The Go side reads everything itself instead of taking a YAML or
// options argument so the extension never has to forward host-app
// state — see the package comment for the rationale.
func Start() error {
	startMu.Lock()
	defer startMu.Unlock()

	if started.Load() {
		return fmt.Errorf("mihomo already started")
	}

	yaml, err := loadActiveYAML()
	if err != nil {
		return err
	}
	cfg, err := prepareConfig(yaml)
	if err != nil {
		return err
	}

	hub.ApplyConfig(cfg)
	startOOMKiller()
	if path := socketPath.Load(); path != "" {
		if err := StartCommandServer(path); err != nil {
			log.Warnln("[command] start server: %v", err)
		}
	}
	started.Store(true)
	return nil
}

// Reload hot-swaps the running mihomo core with a fresh read of the
// active profile YAML and settings.json. Returns an error if the core
// isn't running (caller should fall back to Start) or if the on-disk
// state fails to load / parse.
//
// On iOS, the cached TUN fd from the original Start is reused — the new
// config has the same fd patched in before hub.ApplyConfig, and mihomo's
// listener.ReCreateTun short-circuits when the tun config is unchanged
// (so the kernel-supplied utun socket isn't disturbed). The OOM killer
// and gRPC command server keep running across the reload.
//
// Use this for any change the host wants the extension to pick up:
// profile switch, profile YAML edit, or settings.json toggle. There's no
// separate "settings only" path because hub.ApplyConfig is already
// idempotent and a full re-parse takes well under 100ms.
func Reload() error {
	startMu.Lock()
	defer startMu.Unlock()

	if !started.Load() {
		return fmt.Errorf("mihomo not started")
	}

	yaml, err := loadActiveYAML()
	if err != nil {
		return err
	}
	cfg, err := prepareConfig(yaml)
	if err != nil {
		return err
	}

	hub.ApplyConfig(cfg)
	return nil
}

// prepareConfig parses the YAML and applies the iOS-specific overrides
// that every Start / Reload needs, layering settings.json (controller
// toggle, log level) on top of whatever the YAML carried. The caller
// drives the actual hub.ApplyConfig.
func prepareConfig(yamlConfig []byte) (*config.Config, error) {
	if hd := homeDir.Load(); hd != "" {
		C.SetHomeDir(hd)
	}

	cfg, err := executor.ParseWithBytes(yamlConfig)
	if err != nil {
		return nil, err
	}

	settings := loadSettings()
	applyLogLevel(cfg, settings.LogLevel)
	applyControllerPolicy(cfg, settings.DisableExternalController)
	applyIOSDefaults(cfg)
	if fd := atomic.LoadInt32(&pendingFd); fd > 0 {
		applyTunFd(cfg, int(fd))
	}
	return cfg, nil
}

// applyLogLevel forces the log filter to whatever the host wrote into
// settings.json. The YAML's own `log-level:` is intentionally discarded
// — the host app owns this setting at runtime, and we don't want a
// profile import to silently re-enable debug logging. The runtime
// atomic stays in sync so SetLogLevel callers see the same value.
func applyLogLevel(cfg *config.Config, level int) {
	runtimeLogLevel.Store(int32(level))
	log.SetLevel(log.LogLevel(level))
	cfg.General.LogLevel = log.LogLevel(level)
}

// applyIOSDefaults asserts the few cfg fields that the YAML must not be
// allowed to override on iOS. Profile state is persisted to disk so the
// user's manual proxy selection survives reloads; the geodata loader is
// cleared so mihomo doesn't try to fetch external geo files at startup
// (we ship them bundled).
func applyIOSDefaults(cfg *config.Config) {
	cfg.DNS.Enable = true
	cfg.DNS.EnhancedMode = C.DNSMapping
	cfg.General.GeodataLoader = ""
	cfg.Profile.StoreSelected = true
	cfg.Profile.StoreFakeIP = true
}

// applyControllerPolicy honors the user's "disable external controller"
// toggle. When disabled, every listener form (HTTP/TLS/Unix/pipe) is
// cleared so a YAML that asks for a controller can't sneak one back up.
// When enabled, we bind only to loopback and tighten CORS — mihomo's
// default permits any browser origin, which combined with the loopback
// listener creates a cross-site read primitive.
func applyControllerPolicy(cfg *config.Config, disabled bool) {
	if disabled {
		cfg.Controller.ExternalController = ""
		cfg.Controller.ExternalControllerTLS = ""
		cfg.Controller.ExternalControllerUnix = ""
		cfg.Controller.ExternalControllerPipe = ""
		cfg.Controller.ExternalUI = ""
		cfg.Controller.Secret = ""
		return
	}
	cfg.Controller.ExternalController = "127.0.0.1:9090"
	cfg.Controller.Secret = ""
	cfg.Controller.ExternalUI = "ui"
	cfg.Controller.Cors.AllowOrigins = []string{
		"http://127.0.0.1:*",
		"http://[::1]:*",
		"http://localhost:*",
	}
	cfg.Controller.Cors.AllowPrivateNetwork = false
}

// applyTunFd injects the kernel-supplied utun file descriptor and
// rewrites every Tun field that the YAML profile might have set.
// Routing/interface fields are cleared because NEPacketTunnelNetworkSettings
// owns those on iOS; the gvisor stack is forced because the "System"
// stack makes kernel socket calls the Network Extension entitlement
// doesn't permit. Inet4/Inet6 addresses must match what
// PacketTunnelProvider.configureNetworkSettings installs, otherwise the
// kernel utun delivers packets the virtual stack rejects.
func applyTunFd(cfg *config.Config, fd int) {
	cfg.General.Tun.Enable = true
	cfg.General.Tun.FileDescriptor = fd
	cfg.General.Tun.Device = "" // don't try to open by name
	cfg.General.Tun.Stack = C.TunGvisor
	cfg.General.Tun.AutoRoute = false
	cfg.General.Tun.AutoDetectInterface = false
	cfg.General.Tun.AutoRedirect = false
	cfg.General.Tun.StrictRoute = false
	cfg.General.Interface = ""
	cfg.General.RoutingMark = 0
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

// Stop halts mihomo cleanly. Safe to call multiple times.
func Stop() {
	startMu.Lock()
	defer startMu.Unlock()

	if !started.Load() {
		return
	}
	StopCommandServer()
	stopOOMKiller()
	// Defensive: the host app should also call StopLogFile from
	// stopTunnel, but flushing here ensures the on-disk log is
	// well-formed even if Stop() is reached on an unexpected path.
	StopLogFile()
	executor.Shutdown()
	// Clear the cached fd. iOS may reuse the same integer for an
	// unrelated descriptor on the next session — binding mihomo to a
	// stale fd silently drops every packet.
	atomic.StoreInt32(&pendingFd, 0)
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
//
// Used by the profile editor to validate user input before saving;
// unrelated to the disk-loading path Start / Reload follow.
func Validate(yamlConfig []byte) error {
	if len(yamlConfig) == 0 {
		return fmt.Errorf("config is empty")
	}

	if hd := homeDir.Load(); hd != "" {
		C.SetHomeDir(hd)
	}

	_, err := executor.ParseWithBytes(yamlConfig)
	return err
}

// SetLogLevel changes the runtime log filter. Levels: 0=DEBUG 1=INFO 2=WARNING
// 3=ERROR 4=SILENT. Provided as a no-restart hook for tests / direct callers;
// the host app normally drives this by writing settings.json + asking the
// extension to Reload, which re-reads the file and lands here via
// prepareConfig.
func SetLogLevel(level int) {
	if level < 0 {
		level = 0
	}
	if level > 4 {
		level = 4
	}
	runtimeLogLevel.Store(int32(level))
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
