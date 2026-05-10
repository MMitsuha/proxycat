import Foundation
import Libmihomo

/// Swift-throws wrappers around the gomobile-generated free C functions.
/// gomobile emits `BOOL Func(args, NSError** error)` signatures; Swift only
/// auto-bridges that pattern to `throws` for Obj-C instance methods, not for
/// free functions, so we wrap manually.
///
/// The Go core owns runtime state. Callers configure paths once
/// (home dir, command socket, runtime-settings file, profiles dir, log
/// dir) and then drive lifecycle with `start()` / `reload()` / `stop()`
/// — no YAML or settings flow through these wrappers.
public enum LibmihomoBridge {
    public static func start() throws {
        var err: NSError?
        let ok = LibmihomoStart(&err)
        if !ok {
            throw err ?? makeError("LibmihomoStart returned false")
        }
    }

    /// Hot-swap the running mihomo core. Re-reads runtime_settings.json
    /// and the active profile YAML from disk, then asks mihomo to apply
    /// the new config. The TUN fd, OOM killer, and gRPC command server
    /// keep running across the swap.
    public static func reload() throws {
        var err: NSError?
        let ok = LibmihomoReload(&err)
        if !ok {
            throw err ?? makeError("LibmihomoReload returned false")
        }
    }

    public static func setTunFd(_ fd: Int) throws {
        var err: NSError?
        let ok = LibmihomoSetTunFd(fd, &err)
        if !ok {
            throw err ?? makeError("LibmihomoSetTunFd returned false")
        }
    }

    public static func stop() {
        LibmihomoStop()
    }

    /// Push a runtime log filter directly into mihomo, bypassing the
    /// heavyweight reload path. Levels: 0=DEBUG 1=INFO 2=WARNING
    /// 3=ERROR 4=SILENT. Out-of-range values are clamped on the Go side.
    ///
    /// Called locally by `RuntimeSettings` in the host process so
    /// host-side log emissions (e.g. from `validate()`) honor the
    /// user's choice. The extension's mihomo learns about the change
    /// via the gRPC `SetLogLevel` RPC, not this call.
    public static func setLogLevel(_ level: Int) {
        LibmihomoSetLogLevel(level)
    }

    public static func setHomeDir(_ path: String) {
        LibmihomoSetHomeDir(path)
    }

    /// Tell the embedded gRPC command server where to listen. Path must
    /// be inside the App Group container so the host app can connect.
    public static func setCommandSocketPath(_ path: String) {
        LibmihomoSetCommandSocketPath(path)
    }

    /// Tell mihomo where to bind its REST controller's Unix-domain
    /// listener. Path must be inside the App Group container so the
    /// host app's `MihomoController` can dial it. Pass "" to leave the
    /// Unix listener off (the loopback HTTP listener is governed
    /// separately by `disableExternalController`).
    public static func setControllerSocketPath(_ path: String) {
        LibmihomoSetControllerSocketPath(path)
    }

    /// Tell the Go core where the host app's `runtime_settings.json`
    /// lives. The core re-reads this file on every Start / Reload, so
    /// toggling a setting (or switching the active profile) in the
    /// host UI takes effect on the next reload without shuttling
    /// values through the extension's option dictionary.
    public static func setRuntimeSettingsPath(_ path: String) {
        LibmihomoSetRuntimeSettingsPath(path)
    }

    /// Tell the Go core where the host app's `Profiles/` directory
    /// lives (containing one YAML per profile). Pair with
    /// `setProfileIndexPath` and `setRuntimeSettingsPath` so Start /
    /// Reload can resolve the active YAML themselves — the extension
    /// never reads them.
    public static func setProfilesDir(_ path: String) {
        LibmihomoSetProfilesDir(path)
    }

    /// Tell the Go core where the host app's profile catalog JSON
    /// lives. Decoupled from `setProfilesDir` so the index filename
    /// stays under `AppConfiguration.profileIndexFileName` on the
    /// Swift side rather than being duplicated as a literal in Go.
    public static func setProfileIndexPath(_ path: String) {
        LibmihomoSetProfileIndexPath(path)
    }

    /// Configure the Go OOM killer's per-process memory budget. Pass 0 to
    /// keep the 50 MB default (matches sing-box). The killer will trigger
    /// FreeOSMemory + connection drain when usage reaches limit-safety.
    public static func setMemoryLimit(_ limit: Int64) {
        LibmihomoSetMemoryLimit(limit)
    }

    /// Parses the YAML and throws on syntax / semantic errors. Doesn't
    /// apply anything; safe to call from the host app while the tunnel
    /// is running. Used by the profile editor before saving — unrelated
    /// to the disk-loading path Start / Reload follow.
    public static func validate(yaml: Data) throws {
        var err: NSError?
        LibmihomoValidate(yaml, &err)
        if let err {
            throw err
        }
    }

    /// `validate(yaml:)` on a detached background task — mihomo's parser
    /// can block for hundreds of milliseconds on large configs, so UI
    /// callers should always go through this variant.
    public static func validateAsync(yaml: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try validate(yaml: yaml)
        }.value
    }

    public static func subscribeLogs(_ delegate: LibmihomoLogDelegateProtocol) -> Int64 {
        LibmihomoSubscribeLogs(delegate)
    }

    public static func unsubscribeLogs(_ id: Int64) {
        LibmihomoUnsubscribeLogs(id)
    }

    /// Tell the persist layer where to write per-session log files.
    /// Pass an App Group container path so the host app can read them.
    public static func setLogFileDir(_ path: String) {
        LibmihomoSetLogFileDir(path)
    }

    /// Open a fresh timestamped log file and start streaming every
    /// mihomo log event into it. Returns the absolute path of the
    /// resulting file. Idempotent — a second call returns the active
    /// session's path without rotating.
    @discardableResult
    public static func startLogFile() throws -> String {
        var err: NSError?
        let path = LibmihomoStartLogFile(&err)
        if let err {
            throw err
        }
        return path
    }

    /// Flush + close the active log file. Safe to call multiple times.
    public static func stopLogFile() {
        LibmihomoStopLogFile()
    }

    /// Path of the in-progress log file in this process's Go runtime,
    /// or nil when no session is currently being persisted here. The
    /// host app reads `FilePath.activeLogFilePath()` for extension-owned
    /// log files because the extension runs in a separate process.
    public static func currentLogFilePath() -> String? {
        let s = LibmihomoCurrentLogFilePath()
        return s.isEmpty ? nil : s
    }

    public static func trafficNow() -> LibmihomoTraffic? {
        LibmihomoTrafficNow()
    }

    public static func closeAllConnections() {
        LibmihomoCloseAllConnections()
    }

    /// Tell mihomo that the OS default network interface has changed
    /// (Wi-Fi → cellular, post-sleep reconnect, etc.). Flushes the
    /// interface cache and resets DNS resolver upstream connections so
    /// new traffic doesn't hang on stale TCP/QUIC sockets bound to the
    /// previous route. No-op when the core isn't started.
    ///
    /// On iOS this has to be driven from a Swift NWPathMonitor because
    /// mihomo's bundled DefaultInterfaceMonitor reads the kernel routing
    /// table via AF_ROUTE — a syscall the NE sandbox blocks.
    public static func notifyDefaultInterfaceChanged() {
        LibmihomoNotifyDefaultInterfaceChanged()
    }

    /// Identifying information about the embedded mihomo core. Cached
    /// since the underlying values are baked in at build time.
    public static let version: VersionInfo = .init(LibmihomoVersion())

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "io.proxycat.Libmihomo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public struct VersionInfo: Sendable, Hashable {
    public let mihomo: String
    public let mihomoBuildTime: String
    public let mihomoCommit: String
    public let wrapperBuildTime: String
    public let wrapperCommit: String
    public let buildTags: String
    public let go: String
    public let platform: String
    public let meta: Bool

    init(_ go: LibmihomoVersionInfo?) {
        self.mihomo = go?.mihomo ?? "unknown"
        self.mihomoBuildTime = go?.mihomoBuildTime ?? "unknown"
        self.mihomoCommit = go?.mihomoCommit ?? "unknown"
        self.wrapperBuildTime = go?.wrapperBuildTime ?? "unknown"
        self.wrapperCommit = go?.wrapperCommit ?? "unknown"
        self.buildTags = go?.buildTags ?? ""
        self.go = go?.go ?? ""
        self.platform = go?.platform ?? ""
        self.meta = go?.meta ?? false
    }
}
