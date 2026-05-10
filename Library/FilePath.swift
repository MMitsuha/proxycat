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

    /// Where the Network Extension drops one log file per tunnel session
    /// (`mihomo-YYYYMMDD-HHMMSS.log`). The host app reads the same path
    /// through the App Group container to populate the Saved Logs list.
    public static var logsDirectory: URL {
        ensureSubdirectory("Logs")
    }

    /// Marker written by the Network Extension's Go runtime while a
    /// per-session log file is open. The host app reads it to avoid
    /// deleting or pruning the live file.
    public static var activeLogMarkerFile: URL {
        logsDirectory.appendingPathComponent(AppConfiguration.activeLogMarkerFileName)
    }

    public static func activeLogFilePath() -> String? {
        guard let data = try? Data(contentsOf: activeLogMarkerFile),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
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

    /// Total bytes consumed by mihomo's home directory — the rule-provider
    /// cache.db, the GeoIP / GeoSite / ASN databases, and the downloaded
    /// external UI bundle. Returns 0 on enumeration errors. Profile YAMLs
    /// live in a sibling directory and are not counted. Compile-time
    /// bundled assets (see BundledAssets) are also excluded since they
    /// don't represent reclaimable space.
    public static func cacheSize() -> Int64 {
        let protected = BundledAssets.protectedTopLevelNames
        let workingPath = workingDirectory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: workingDirectory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if isUnderProtectedTopLevel(url: url, workingPath: workingPath, protected: protected) {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Enforce the user's saved-log retention policy. Counts only
    /// `mihomo-*.log` files in `logsDirectory`, sorts newest-first by
    /// mtime, and deletes everything past the policy's keep count.
    /// The file the extension is currently writing to is always
    /// preserved — deleting an open inode silently keeps growing it.
    /// Idempotent and cheap; safe to call from app foreground, view
    /// reload, and settings-change sinks.
    public static func pruneSavedLogs(policy: LogRetention, activePath: String? = activeLogFilePath()) {
        let keep = policy.rawValue
        guard keep > 0 else { return }

        let dir = logsDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let candidates: [(url: URL, modified: Date)] = urls.compactMap { url in
            // Match the writer's naming scheme (mihomo-YYYYMMDD-HHMMSS.log).
            // Anything else dropped in here — a future feature's file, a
            // test artifact — is left alone instead of being silently
            // counted against the retention budget.
            guard url.pathExtension == "log",
                  url.lastPathComponent.hasPrefix("mihomo-"),
                  url.path != activePath,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }

        // Active file doesn't count against the keep budget — it's
        // implicitly always kept, separate from the policy. So if
        // policy=last10 and there are 11 inactive + 1 active, we keep
        // 10 inactive + 1 active = 11 files total on disk.
        guard candidates.count > keep else { return }

        let sorted = candidates.sorted { $0.modified > $1.modified }
        for entry in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Removes everything inside `workingDirectory` so mihomo will
    /// re-fetch its caches on the next start. Profiles are untouched,
    /// and any compile-time bundled assets (see BundledAssets) are
    /// preserved so the user doesn't lose embedded geo databases /
    /// external UI to a Clear Cache tap.
    ///
    /// Safe to call while the tunnel is running, with one caveat: bbolt
    /// keeps writing to the cache.db inode it has already opened (Unix
    /// unlink-while-open semantics), so until the extension restarts the
    /// reclaimed disk space won't actually free.
    public static func clearCache() throws {
        let fm = FileManager.default
        let protected = BundledAssets.protectedTopLevelNames
        let entries = try fm.contentsOfDirectory(at: workingDirectory, includingPropertiesForKeys: nil)
        for entry in entries {
            if protected.contains(entry.lastPathComponent) { continue }
            try fm.removeItem(at: entry)
        }
    }

    private static func isUnderProtectedTopLevel(
        url: URL,
        workingPath: String,
        protected: Set<String>
    ) -> Bool {
        guard !protected.isEmpty else { return false }
        let entryPath = url.standardizedFileURL.path
        guard entryPath.hasPrefix(workingPath) else { return false }
        var relative = String(entryPath.dropFirst(workingPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard let firstComponent = relative.split(separator: "/").first.map(String.init) else {
            return false
        }
        return protected.contains(firstComponent)
    }
}
