import Foundation
import os

public enum FilePath {
    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "FilePath")
    private static var fallbackWarned = false

    /// Container shared between the host app and the Network Extension.
    /// On a properly-signed device this is the App-Group container. On
    /// the simulator (or any build without the entitlement) we fall back
    /// to the app's own Documents so the UI still works for testing —
    /// the extension's IPC won't function across processes in that case
    /// and a warning is logged once.
    public static var sharedDirectory: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupID
        ) {
            return url
        }
        if !fallbackWarned {
            fallbackWarned = true
            logger.warning("App group container unavailable for \(AppConfiguration.appGroupID, privacy: .public); falling back to per-process Documents — IPC across host/extension will not work in this build")
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = docs.appendingPathComponent("FallbackAppGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var profilesDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var workingDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Working", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var cacheDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
}
