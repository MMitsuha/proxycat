import Foundation

/// Filesystem maintenance for the App Group container: cache sizing,
/// cache clearing, and saved-log retention. Kept separate from
/// `FilePath` (which only resolves locations) so path resolution stays
/// side-effect free.
public enum StorageMaintenance {
    /// Total bytes consumed by mihomo's home directory — the rule-provider
    /// cache.db, the GeoIP / GeoSite / ASN databases, and the downloaded
    /// external UI bundle. Returns 0 on enumeration errors. Profile YAMLs
    /// live in a sibling directory and are not counted. Compile-time
    /// bundled assets (see BundledAssets) are also excluded since they
    /// don't represent reclaimable space.
    public static func cacheSize() -> Int64 {
        let protected = protectedWorkingDirectoryNames
        let workingPath = FilePath.workingDirectory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: FilePath.workingDirectory,
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
    /// managed per-session log files in `logsDirectory`, grouping
    /// mihomo and proxycat logs separately so "last 10" keeps both
    /// sides of roughly the last 10 sessions.
    /// Files the extension is currently writing to are always
    /// preserved — deleting an open inode silently keeps growing it.
    /// Idempotent and cheap; safe to call from app foreground, view
    /// reload, and settings-change sinks.
    public static func pruneSavedLogs(
        policy: LogRetention,
        activePaths: Set<String> = FilePath.activeLogFilePaths()
    ) {
        let keep = policy.rawValue
        guard keep > 0 else { return }

        let dir = FilePath.logsDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        // Parse each URL into a SavedLogFileInfo so retention groups,
        // sorting, and the "managed" filter all rely on a single
        // filename-format check. Malformed filenames are silently
        // skipped — same behaviour as the SavedLogsView listing, so
        // the list and the pruner never disagree on what counts.
        let candidates = urls.compactMap { url -> SavedLogFileInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return SavedLogFileInfo.parse(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                isActive: activePaths.contains(url.path)
            )
        }
        .filter { !$0.isActive }

        // Sort by startedAt desc, with a filename tiebreak so two
        // sessions that opened in the same wall-clock second
        // (writer appends `-N` to the second one's filename) have a
        // deterministic order. Pruning then picks the same survivor
        // every run, which matters because the user may delete by
        // hand from the list and expect retention to keep "the same
        // ones" next time. Retention drops the oldest *sessions* —
        // going by mtime would let an active session's last write
        // reorder old, finished sessions and accidentally evict a
        // sibling kind on the same disk write.
        for entries in Dictionary(grouping: candidates, by: \.kind).values {
            guard entries.count > keep else { continue }
            let sorted = entries.sorted(by: orderByStartedAtDesc)
            for entry in sorted.dropFirst(keep) {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    /// Shared comparator used by both `pruneSavedLogs` and the
    /// SavedLogsView listing so the on-disk file the user sees at
    /// position N is exactly the file that survives at position N
    /// after a retention sweep. Newer session → earlier in the list;
    /// fileName breaks ties so same-second collisions stay stable.
    public static func orderByStartedAtDesc(_ lhs: SavedLogFileInfo, _ rhs: SavedLogFileInfo) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.fileName < rhs.fileName
    }

    public static func isManagedSavedLogFile(_ url: URL) -> Bool {
        SavedLogFileInfo.Kind.matching(filename: url.lastPathComponent) != nil
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
        let protected = protectedWorkingDirectoryNames
        let entries = try fm.contentsOfDirectory(at: FilePath.workingDirectory, includingPropertiesForKeys: nil)
        for entry in entries {
            if protected.contains(entry.lastPathComponent) { continue }
            try fm.removeItem(at: entry)
        }
    }

    private static var protectedWorkingDirectoryNames: Set<String> {
        BundledAssets.protectedTopLevelNames
            .union([
                FilePath.mitmCertificateFile.lastPathComponent,
                FilePath.mitmPrivateKeyFile.lastPathComponent,
            ])
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
