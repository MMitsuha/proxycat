import Foundation

public enum FilePath {
    private static let logger = ProxyCatLogger(subsystem: "io.proxycat.Library", category: "FilePath")

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
        logger.warning("App group container unavailable for \(AppConfiguration.appGroupID); falling back to per-process Documents - IPC across host/extension will not work in this build")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = docs.appendingPathComponent("FallbackAppGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static var profilesDirectory: URL {
        ensureSubdirectory("Profiles")
    }

    /// Location of one profile YAML inside `Profiles/`. Centralizes the
    /// directory + filename composition used by the store, backup
    /// pipeline, editor, and share export.
    public static func profileURL(named fileName: String) -> URL {
        profilesDirectory.appendingPathComponent(fileName)
    }

    public static var workingDirectory: URL {
        ensureSubdirectory("Working")
    }

    public static var mitmCertificateFile: URL {
        workingDirectory.appendingPathComponent("mitm_ca.crt")
    }

    public static var mitmPrivateKeyFile: URL {
        workingDirectory.appendingPathComponent("mitm_ca.key")
    }

    /// Where the Network Extension drops per-session log files
    /// (`mihomo-YYYYMMDD-HHMMSS.log` from Go and
    /// `proxycat-YYYYMMDD-HHMMSS.log` from Swift). The host app reads the
    /// same path through the App Group container to populate Saved Logs.
    public static var logsDirectory: URL {
        ensureSubdirectory("Logs")
    }

    /// Marker written by the Network Extension's Go runtime while a
    /// per-session log file is open. The host app reads it to avoid
    /// deleting or pruning the live file.
    public static var activeLogMarkerFile: URL {
        logsDirectory.appendingPathComponent(AppConfiguration.activeLogMarkerFileName)
    }

    /// Marker for the Swift-side per-session log currently being written.
    public static var activeProxyCatLogMarkerFile: URL {
        logsDirectory.appendingPathComponent(AppConfiguration.activeProxyCatLogMarkerFileName)
    }

    /// Paths of the per-process log files the Network Extension is
    /// currently writing into (one for the Go-side mihomo log, one
    /// for the Swift-side ProxyCat log). Used to keep those files
    /// out of retention pruning and to render the LIVE badge.
    public static func activeLogFilePaths() -> Set<String> {
        Set([activeLogMarkerFile, activeProxyCatLogMarkerFile].compactMap { activeLogPath(from: $0) })
    }

    private static func activeLogPath(from marker: URL) -> String? {
        guard let data = try? Data(contentsOf: marker),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        return resolvedActiveLogPath(
            storedPath: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            logsDirectory: logsDirectory
        )
    }

    /// Resolve the path stored in an extension-written marker.
    ///
    /// App container UUIDs change when the app is reinstalled or updated,
    /// while the extension's marker file can survive with its old
    /// absolute path. Prefer the stored path when it still exists, then
    /// fall back to the same filename inside the current logs directory.
    nonisolated static func resolvedActiveLogPath(
        storedPath: String,
        logsDirectory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard !storedPath.isEmpty else { return nil }
        if fileExists(storedPath) {
            return storedPath
        }

        let name = URL(fileURLWithPath: storedPath).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let candidate = logsDirectory.appendingPathComponent(name).path
        return fileExists(candidate) ? candidate : nil
    }

    /// Path of the Unix-domain command socket. Both the Network
    /// Extension (server) and the host app (client) compute it the
    /// same way, so they meet at the App Group container. The path
    /// stays well below sun_path's 104-byte limit.
    public static var commandSocketPath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.commandSocketName).path
    }

    /// Path of the Unix-domain socket where mihomo's REST controller
    /// binds. Same App-Group rendezvous as `commandSocketPath` but
    /// carries HTTP — the native UI controller dials it for proxies,
    /// connections, and group-delay calls without going through the
    /// loopback HTTP listener.
    public static var controllerSocketPath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.controllerSocketName).path
    }

    /// Path of the shared runtime-settings JSON. The host app's
    /// `RuntimeSettings` writes it; the Go core reads it on every
    /// Start / Reload. Holds the active profile UUID alongside the
    /// runtime preference fields, so a single file configures
    /// everything the Go core needs at lifecycle events.
    public static var runtimeSettingsFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.runtimeSettingsFileName).path
    }

    /// Path of the host-only settings JSON. Sits next to
    /// `runtime_settings.json` in the App Group root so the same set
    /// of paths configures every persistence consumer. Read/written
    /// only by the host app; the Go core never touches it.
    public static var hostSettingsFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.hostSettingsFileName).path
    }

    /// Local metadata for iCloud sync. Kept in the App Group so the app
    /// preserves the user's sync preference across launches, but not
    /// read by the Network Extension or mirrored to iCloud.
    public static var iCloudSyncStateFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.iCloudSyncStateFileName).path
    }

    /// Path of the rolling daily-traffic log JSON. Read/written only by
    /// the host app's `DailyUsageStore`.
    public static var dailyUsageFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.dailyUsageFileName).path
    }

    /// Path of the profile catalog JSON. Lives inside the profiles
    /// directory; the Go core reads it to resolve the active profile
    /// UUID to a YAML path. Both `ProfileStore` (host) and
    /// `LibmihomoBridge.setProfileIndexPath` (extension) compute the
    /// same path through this helper so the literal lives in one place.
    public static var profileIndexFilePath: String {
        profilesDirectory.appendingPathComponent(AppConfiguration.profileIndexFileName).path
    }

    private static func ensureSubdirectory(_ name: String) -> URL {
        let url = sharedDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}
