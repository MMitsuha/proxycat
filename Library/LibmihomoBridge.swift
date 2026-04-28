import Foundation
import Libmihomo

/// Swift-throws wrappers around the gomobile-generated free C functions.
/// gomobile emits `BOOL Func(args, NSError** error)` signatures; Swift only
/// auto-bridges that pattern to `throws` for Obj-C instance methods, not for
/// free functions, so we wrap manually.
public enum LibmihomoBridge {
    public static func start(yaml: Data) throws {
        var err: NSError?
        let ok = LibmihomoStart(yaml, &err)
        if !ok {
            throw err ?? makeError("LibmihomoStart returned false")
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

    public static func setLogLevel(_ level: Int) {
        LibmihomoSetLogLevel(level)
    }

    public static func setHomeDir(_ path: String) {
        LibmihomoSetHomeDir(path)
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
    /// is running.
    public static func validate(yaml: Data) throws {
        var err: NSError?
        LibmihomoValidate(yaml, &err)
        if let err {
            throw err
        }
    }

    public static func subscribeLogs(_ delegate: LibmihomoLogDelegateProtocol) -> Int64 {
        LibmihomoSubscribeLogs(delegate)
    }

    public static func unsubscribeLogs(_ id: Int64) {
        LibmihomoUnsubscribeLogs(id)
    }

    public static func trafficNow() -> LibmihomoTraffic? {
        LibmihomoTrafficNow()
    }

    public static func closeAllConnections() {
        LibmihomoCloseAllConnections()
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "io.proxycat.Libmihomo", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
