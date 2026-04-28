import Foundation
import os

public enum FilePath {
    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "FilePath")

    /// Container shared between the host app and the Network Extension.
    /// On a properly-signed device this is the App-Group container. On
    /// the simulator (or any build without the entitlement) we fall back
    /// to the app's own Documents so the UI still works for testing —
    /// the extension's IPC won't function across processes in that case
    /// and a warning is logged once.
    public static var sharedDirectory: URL { resolvedShared }

    // `static let` is dispatch_once-protected, so the resolution and
    // accompanying warning fire exactly once per process regardless of
    // how many threads first touch sharedDirectory simultaneously.
    private static let resolvedShared: URL = {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupID
        ) {
            return url
        }
        logger.warning(
            "App group container unavailable for \(AppConfiguration.appGroupID, privacy: .public); falling back to per-process Documents — IPC across host/extension will not work in this build"
        )
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = docs.appendingPathComponent("FallbackAppGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static var profilesDirectory: URL {
        ensureSubdirectory("Profiles")
    }

    public static var workingDirectory: URL {
        ensureSubdirectory("Working")
    }

    public static var cacheDirectory: URL {
        ensureSubdirectory("Cache")
    }

    /// Where the active profile selection (just a filename) is persisted.
    public static var activeProfilePointer: URL {
        sharedDirectory.appendingPathComponent("active-profile")
    }

    /// Path of the Unix-domain command socket. Both the Network
    /// Extension (server) and the host app (client) compute it the
    /// same way, so they meet at the App Group container. The path
    /// stays well below sun_path's 104-byte limit.
    public static var commandSocketPath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.commandSocketName).path
    }

    private static func ensureSubdirectory(_ name: String) -> URL {
        let url = sharedDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
