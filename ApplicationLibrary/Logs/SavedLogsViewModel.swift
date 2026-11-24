import Foundation
import Library
import Observation

/// Loads one saved log document off the main actor. The view keeps one
/// instance per navigated file.
@MainActor @Observable
final class SavedLogFileViewModel {
    var document: SavedLogDocument?
    var loadError: String?
    var isLoading = false

    func load(path: String, force: Bool = false) async {
        guard force || document == nil else { return }
        isLoading = true
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try SavedLogFileReader.load(path: path)
            }.value
            document = loaded
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

/// Browse model for the per-session log files. Directory listing,
/// retention pruning, and deletion all run off the main actor — a
/// long-lived install can hold a hundred files per kind, and the
/// listing previously blocked the first frame of the screen.
@MainActor @Observable
final class SavedLogsViewModel {
    var entries: [SavedLogFileInfo] = []
    var confirmDeleteAll: Bool = false

    /// Count shown in the "delete all" confirmation. Excludes the
    /// LIVE session(s) because `deleteAll()` skips them — the user
    /// needs to know exactly how many files will disappear.
    var deletableCount: Int {
        entries.lazy.filter { !$0.isActive }.count
    }

    func reload() async {
        let retention = HostSettingsStore.shared.logRetention
        let parsed = await Task.detached(priority: .userInitiated) {
            let active = FilePath.activeLogFilePaths()
            // Apply the user's retention policy before listing so the
            // list always reflects what is actually on disk.
            StorageMaintenance.pruneSavedLogs(policy: retention, activePaths: active)

            let urls = (try? FileManager.default.contentsOfDirectory(
                at: FilePath.logsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            return urls.compactMap { url -> SavedLogFileInfo? in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                ),
                    values.isRegularFile == true
                else { return nil }
                return SavedLogFileInfo.parse(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    isActive: active.contains(url.path)
                )
            }
            // Newest-session first. Sort matches the retention pruner
            // so the position the user sees is the position retention
            // operates on.
            .sorted(by: StorageMaintenance.orderByStartedAtDesc)
        }.value
        guard !Task.isCancelled else { return }
        entries = parsed
    }

    func delete(at offsets: IndexSet) async {
        let urls = offsets.compactMap { index -> URL? in
            guard entries.indices.contains(index), !entries[index].isActive else { return nil }
            return entries[index].url
        }
        guard !urls.isEmpty else { return }
        await removeFiles(urls)
        await reload()
    }

    func deleteAll() async {
        let urls = entries.lazy.filter { !$0.isActive }.map(\.url)
        await removeFiles(Array(urls))
        await reload()
    }

    /// Never deletes the file the extension is currently writing into:
    /// the unlink succeeds on iOS but the open inode keeps growing in
    /// the dark, permanently leaking disk space.
    private func removeFiles(_ urls: [URL]) async {
        await Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
}
