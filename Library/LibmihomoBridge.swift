import Foundation
import Libmihomo

/// Swift-throws wrappers around the gomobile-generated free C functions.
/// gomobile emits `BOOL Func(args, NSError** error)` signatures; Swift only
/// auto-bridges that pattern to `throws` for Obj-C instance methods, not for
/// free functions, so we wrap manually.
///
/// The Go core owns runtime state. Callers configure paths once
/// (home dir, command socket, settings file, profiles dir, active-profile
/// pointer, log dir) and then drive lifecycle with `start()` / `reload()` /
/// `stop()` — no YAML or settings flow through these wrappers.
public enum LibmihomoBridge {
    public static func start() throws {
        var err: NSError?
        let ok = LibmihomoStart(&err)
        if !ok {
            throw err ?? makeError("LibmihomoStart returned false")
        }
    }

    /// Hot-swap the running mihomo core. Re-reads the active-profile YAML
    /// and runtime settings from disk, then asks mihomo to apply the new
    /// config. The TUN fd, OOM killer, and gRPC command server keep
    /// running across the swap.
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

    /// Push a runtime log filter without going through Reload. Used as a
    /// no-restart hook for tests / direct callers; the host app normally
    /// drives this by writing settings.json + asking the extension to
    /// `reload()`, which re-reads the file and lands in the same place.
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

    /// Tell the Go core where the host app's `settings.json` lives. The
    /// core re-reads this file on every Start / Reload, so toggling a
    /// setting in the host UI takes effect on the next reload without
    /// shuttling values through the extension's IPC.
    public static func setSettingsPath(_ path: String) {
        LibmihomoSetSettingsPath(path)
    }

    /// Tell the Go core where the host app's `active-profile` UUID file
    /// lives. Combined with `setProfilesDir` this lets Start / Reload
    /// load the active YAML themselves — the extension never reads it.
    public static func setActiveProfilePointer(_ path: String) {
        LibmihomoSetActiveProfilePointer(path)
    }

    /// Tell the Go core where the host app's `Profiles/` directory
    /// lives (containing `index.json` plus one YAML per profile).
    public static func setProfilesDir(_ path: String) {
        LibmihomoSetProfilesDir(path)
    }

    /// Configure the Go OOM killer's per-process memory budget. Pass 0 to
    /// keep the 50 MB default (matches sing-box). The killer will trigger
    /// FreeOSMemory + connection drain when usage reaches limit-safety.
    public static func setMemoryLimit(_ limit: Int64) {
        LibmihomoSetMemoryLimit(limit)
    }

    /// Current process resident memory (phys_footprint). Same source the
    /// Go OOM killer reads, so dashboards using this match its perspective.
    public static func memoryUsage() -> Int64 {
        LibmihomoMemoryUsage()
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

    /// Path of the in-progress log file, or nil when no session is
    /// currently being persisted.
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
    public let buildTags: String
    public let go: String
    public let platform: String
    public let meta: Bool

    init(_ go: LibmihomoVersionInfo?) {
        self.mihomo = go?.mihomo ?? "unknown"
        self.mihomoBuildTime = go?.mihomoBuildTime ?? "unknown"
        self.mihomoCommit = go?.mihomoCommit ?? "unknown"
        self.wrapperBuildTime = go?.wrapperBuildTime ?? "unknown"
        self.buildTags = go?.buildTags ?? ""
        self.go = go?.go ?? ""
        self.platform = go?.platform ?? ""
        self.meta = go?.meta ?? false
    }
}
