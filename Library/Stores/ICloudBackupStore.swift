import Foundation
import Observation

@MainActor @Observable
public final class ICloudBackupStore {
    public static let shared = ICloudBackupStore()

    public var isEnabled: Bool {
        didSet {
            guard loaded, isEnabled != oldValue else { return }
            state.isEnabled = isEnabled
            persistState()
            // Any in-flight sync checks this generation before every
            // side effect, so turning sync off aborts it instead of
            // letting a stale reconcile still upload or overwrite.
            syncGeneration &+= 1
            if isEnabled {
                installObserversIfNeeded()
                Task { await syncNow() }
            } else {
                scheduledSyncTask?.cancel()
                needsSync = false
                phase = .disabled
            }
        }
    }

    public private(set) var phase: ICloudBackupPhase
    public private(set) var isSyncing = false
    public private(set) var lastBackup: ICloudBackupSummary?
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var state: ICloudSyncState
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var scheduledSyncTask: Task<Void, Never>?
    /// Set when a sync request arrives while another is running; the
    /// active run folds it in with a follow-up reconcile instead of
    /// dropping the change until some unrelated event triggers a sync.
    @ObservationIgnored private var needsSync = false
    /// Bumped whenever `isEnabled` flips so in-flight work can detect
    /// that the user turned sync off (or off-and-on).
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private var activeSyncGeneration: Int?

    private enum SyncInterruption: Error {
        case disabled
    }
    @ObservationIgnored private let logger = ProxyCatLogger(subsystem: "io.proxycat.Library", category: "ICloudBackupStore")

    private init() {
        let state = JSONFileStore.load(
            ICloudSyncState.self,
            at: FilePath.iCloudSyncStateFilePath,
            default: .defaults
        )
        self.state = state
        self.isEnabled = state.isEnabled
        self.phase = state.isEnabled ? .ready : .disabled
        self.lastSyncedAt = state.lastSyncedAt
        self.loaded = true
    }

    public var hasCloudBackup: Bool {
        lastBackup != nil
    }

    public func startAutoSync() {
        installObserversIfNeeded()
        guard isEnabled else {
            phase = .disabled
            return
        }
        Task { await syncNow() }
    }

    public func refreshStatus() async {
        guard isEnabled else {
            phase = .disabled
            return
        }

        do {
            let url = try await Self.backupFileURL()
            if let snapshot = try await Self.readSnapshotIfExists(at: url) {
                lastBackup = ICloudBackupSummary(snapshot: snapshot)
            } else {
                lastBackup = nil
            }
            // A previous reconcile found a real conflict. Opening the
            // screen (or foregrounding) must not clear that warning —
            // only a successful sync/restore resolves it.
            if phase != .conflict {
                phase = isSyncing ? .syncing : .ready
                lastError = nil
            }
        } catch {
            setFailure(error)
        }
    }

    public func syncNow() async {
        guard isEnabled else {
            phase = .disabled
            return
        }
        await runSync {
            try await self.reconcile()
        }
    }

    public func backUpNow() async {
        guard isEnabled else {
            phase = .disabled
            return
        }
        await runSync {
            try self.ensureEnabled()
            let content = try await self.currentContent()
            try self.ensureEnabled()
            let snapshot = ICloudBackupSnapshot(
                sourceDeviceID: self.state.deviceID,
                appVersion: Self.appVersion,
                content: content
            )
            let url = try await Self.backupFileURL()
            try self.ensureEnabled()
            try await Self.writeSnapshot(snapshot, to: url)
            try self.ensureEnabled()
            try self.updateSyncedState(snapshot: snapshot, checksum: ICloudBackupSnapshot.checksum(for: content))
        }
    }

    public func restoreNow() async {
        guard isEnabled else {
            phase = .disabled
            return
        }
        await runSync {
            try self.ensureEnabled()
            let url = try await Self.backupFileURL()
            guard let snapshot = try await Self.readSnapshotIfExists(at: url) else {
                throw ICloudBackupError.missingBackup
            }
            try self.ensureEnabled()
            try await self.apply(snapshot)
            try self.ensureEnabled()
            try self.updateSyncedState(
                snapshot: snapshot,
                checksum: ICloudBackupSnapshot.checksum(for: snapshot.content)
            )
        }
    }

    private func reconcile() async throws {
        try ensureEnabled()
        let localContent = try await currentContent()
        try ensureEnabled()

        let localChecksum = try ICloudBackupSnapshot.checksum(for: localContent)
        let url = try await Self.backupFileURL()
        try ensureEnabled()

        guard let cloudSnapshot = try await Self.readSnapshotIfExists(at: url) else {
            let snapshot = ICloudBackupSnapshot(
                sourceDeviceID: state.deviceID,
                appVersion: Self.appVersion,
                content: localContent
            )
            try ensureEnabled()
            try await Self.writeSnapshot(snapshot, to: url)
            try ensureEnabled()
            try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
            return
        }
        try ensureEnabled()

        let cloudChecksum = try ICloudBackupSnapshot.checksum(for: cloudSnapshot.content)
        if localChecksum == cloudChecksum {
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        if let lastSyncedChecksum = state.lastSyncedChecksum {
            if localChecksum == lastSyncedChecksum {
                try ensureEnabled()
                try await apply(cloudSnapshot)
                try ensureEnabled()
                try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
                return
            }
            if cloudChecksum == lastSyncedChecksum {
                let snapshot = ICloudBackupSnapshot(
                    sourceDeviceID: state.deviceID,
                    appVersion: Self.appVersion,
                    content: localContent
                )
                try ensureEnabled()
                try await Self.writeSnapshot(snapshot, to: url)
                try ensureEnabled()
                try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
                return
            }
            throw ICloudBackupError.conflict
        }

        if localContent.profiles.isEmpty, !cloudSnapshot.content.profiles.isEmpty {
            try ensureEnabled()
            try await apply(cloudSnapshot)
            try ensureEnabled()
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        let localModifiedAt = await Self.localModifiedDate()
        try ensureEnabled()
        if let localModifiedAt, cloudSnapshot.createdAt > localModifiedAt {
            try ensureEnabled()
            try await apply(cloudSnapshot)
            try ensureEnabled()
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        let snapshot = ICloudBackupSnapshot(
            sourceDeviceID: state.deviceID,
            appVersion: Self.appVersion,
            content: localContent
        )
        try ensureEnabled()
        try await Self.writeSnapshot(snapshot, to: url)
        try ensureEnabled()
        try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
    }

    private func runSync(_ operation: @escaping () async throws -> Void) async {
        guard isEnabled else {
            needsSync = false
            phase = .disabled
            return
        }
        guard !isSyncing else {
            // Don't drop the request: fold it into a follow-up reconcile
            // once the current attempt finishes.
            needsSync = true
            return
        }

        isSyncing = true
        phase = .syncing
        defer {
            isSyncing = false
            activeSyncGeneration = nil
        }

        var firstAttempt = true
        while true {
            needsSync = false
            activeSyncGeneration = syncGeneration
            var completed = false
            do {
                if firstAttempt {
                    try await operation()
                } else {
                    // A request arrived while the original operation ran.
                    // Reconcile instead of repeating a user-initiated
                    // restore/backup against a newer local state.
                    try await reconcile()
                }
                completed = true
                firstAttempt = false
            } catch is SyncInterruption {
                // The user disabled sync (or toggled it off and on)
                // while this attempt was in flight. Fall through so a
                // re-enable can still pick up pending work.
            } catch {
                setFailure(error)
                return
            }

            guard isEnabled else {
                phase = .disabled
                return
            }
            guard needsSync else {
                phase = .ready
                if completed {
                    lastError = nil
                }
                return
            }
            // Loop again with a fresh generation check.
        }
    }

    /// Throws when sync was disabled or re-toggled since the current
    /// attempt began. Called after every await and before every cloud
    /// read/write side effect.
    private func ensureEnabled() throws {
        guard isEnabled, activeSyncGeneration == syncGeneration else {
            throw SyncInterruption.disabled
        }
    }

    private func currentContent() async throws -> ICloudBackupContent {
        let profiles = ProfileStore.shared.profiles
        let entries = try await Self.profileEntries(from: profiles)
        // The web editor is a device-local security surface: never
        // restore an open LAN port from cloud data, and keep toggling it
        // from perturbing the backup checksum.
        let hostSettings = HostSettingsStore.shared.snapshot.backupCopy
        return ICloudBackupContent(
            runtimeSettings: RuntimeSettings.shared.snapshot,
            hostSettings: hostSettings,
            profiles: entries
        )
    }

    private func apply(_ snapshot: ICloudBackupSnapshot) async throws {
        try ensureEnabled()
        try Self.validate(snapshot)
        let profiles = snapshot.content.profiles.map(\.profile)
        let contentsByID = Dictionary(uniqueKeysWithValues: snapshot.content.profiles.map { ($0.profile.id, $0.yaml) })
        let repairedActiveProfileID = ProfileStore.repairedActiveProfileID(
            profiles: profiles,
            storedID: snapshot.content.runtimeSettings.activeProfileID
        )
        var runtimeSettings = snapshot.content.runtimeSettings
        runtimeSettings.activeProfileID = repairedActiveProfileID
        try await ProfileStore.shared.replaceAll(
            with: profiles,
            contentsByID: contentsByID,
            activeProfileID: repairedActiveProfileID
        )
        RuntimeSettings.shared.replace(with: runtimeSettings)
        var hostSettings = snapshot.content.hostSettings
        hostSettings.webEditor = HostSettingsStore.shared.webEditor
        HostSettingsStore.shared.replace(with: hostSettings)
    }

    private func updateSyncedState(snapshot: ICloudBackupSnapshot, checksum: String) throws {
        state.lastSyncedChecksum = checksum
        state.lastSyncedAt = Date()
        state.lastCloudSnapshotID = snapshot.id
        lastSyncedAt = state.lastSyncedAt
        lastBackup = ICloudBackupSummary(snapshot: snapshot)
        persistState()
    }

    private func persistState() {
        guard JSONFileStore.saveOrLog(
            state,
            to: FilePath.iCloudSyncStateFilePath,
            category: "ICloudBackupStore"
        ) else {
            logger.error("Failed to persist iCloud sync state")
            return
        }
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            ProfileStore.catalogDidChange,
            ProfileStore.activeContentDidChange,
            AppConfiguration.runtimeSettingsDidChange,
            AppConfiguration.runtimeLogLevelDidChange,
            AppConfiguration.hostSettingsDidChange,
        ]
        observerTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleSync()
                }
            }
        }
    }

    private func scheduleSync() {
        guard isEnabled else { return }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func setFailure(_ error: Error) {
        if error as? ICloudBackupError == .conflict {
            phase = .conflict
        } else if error as? ICloudBackupError == .unavailable {
            phase = .unavailable
        } else {
            phase = .error(error.localizedDescription)
        }
        lastError = error.localizedDescription
    }

    private nonisolated static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private nonisolated static func validate(_ snapshot: ICloudBackupSnapshot) throws {
        guard snapshot.schemaVersion == ICloudBackupSnapshot.currentSchemaVersion else {
            throw ICloudBackupError.unsupportedVersion(snapshot.schemaVersion)
        }
        let profiles = snapshot.content.profiles.map(\.profile)
        let contentsByID = Dictionary(uniqueKeysWithValues: snapshot.content.profiles.map { ($0.profile.id, $0.yaml) })
        _ = try ProfileStore.validatedRestoreProfiles(profiles, contentsByID: contentsByID)
    }

    private nonisolated static func profileEntries(from profiles: [Profile]) async throws -> [ICloudBackupProfile] {
        try await Task.detached(priority: .userInitiated) {
            try profiles.map { profile in
                let url = FilePath.profileURL(named: profile.fileName)
                let yaml = try String(contentsOf: url, encoding: .utf8)
                return ICloudBackupProfile(profile: profile, yaml: yaml)
            }
        }.value
    }

    private nonisolated static func backupFileURL() async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.ubiquityIdentityToken != nil else {
                throw ICloudBackupError.unavailable
            }
            guard let container = fm.url(forUbiquityContainerIdentifier: AppConfiguration.iCloudContainerID) else {
                throw ICloudBackupError.unavailable
            }
            let directory = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("ProxyCat", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(AppConfiguration.iCloudBackupFileName)
        }.value
    }

    private nonisolated static func readSnapshotIfExists(at url: URL) async throws -> ICloudBackupSnapshot? {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return nil }
            try? fm.startDownloadingUbiquitousItem(at: url)
            let data = try Data(contentsOf: url)
            let snapshot = try ICloudBackupSnapshot.decoder.decode(ICloudBackupSnapshot.self, from: data)
            try validate(snapshot)
            return snapshot
        }.value
    }

    private nonisolated static func writeSnapshot(_ snapshot: ICloudBackupSnapshot, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try validate(snapshot)
            let data = try ICloudBackupSnapshot.fileEncoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        }.value
    }

    private nonisolated static func localModifiedDate() async -> Date? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var dates: [Date] = []
            // host_settings.json is intentionally excluded: it also holds
            // the device-local web editor toggle and port, which are never
            // backed up. Without this, toggling the editor would rewrite
            // the file's mtime and make untouched local profiles look newer
            // than an existing cloud snapshot in the tie-break below.
            let fileURLs = [
                URL(fileURLWithPath: FilePath.runtimeSettingsFilePath),
                URL(fileURLWithPath: FilePath.profileIndexFilePath),
            ]
            for url in fileURLs {
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = values.contentModificationDate {
                    dates.append(date)
                }
            }
            if let profileURLs = try? fm.contentsOfDirectory(
                at: FilePath.profilesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in profileURLs where url.pathExtension == "yaml" || url.pathExtension == "yml" {
                    if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let date = values.contentModificationDate {
                        dates.append(date)
                    }
                }
            }
            return dates.max()
        }.value
    }
}

private struct ICloudSyncState: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var deviceID: UUID
    var lastSyncedChecksum: String?
    var lastSyncedAt: Date?
    var lastCloudSnapshotID: UUID?

    static let defaults = ICloudSyncState(
        isEnabled: false,
        deviceID: UUID(),
        lastSyncedChecksum: nil,
        lastSyncedAt: nil,
        lastCloudSnapshotID: nil
    )
}
