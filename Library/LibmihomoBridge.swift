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
