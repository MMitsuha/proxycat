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
            if isEnabled {
                installObserversIfNeeded()
                Task { await syncNow() }
            } else {
                scheduledSyncTask?.cancel()
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
            let content = try await self.currentContent()
            let snapshot = ICloudBackupSnapshot(
                sourceDeviceID: self.state.deviceID,
                appVersion: Self.appVersion,
                content: content
            )
            let url = try await Self.backupFileURL()
            try await Self.writeSnapshot(snapshot, to: url)
            try self.updateSyncedState(snapshot: snapshot, checksum: ICloudBackupSnapshot.checksum(for: content))
        }
    }

    public func restoreNow() async {
        guard isEnabled else {
            phase = .disabled
            return
        }
        await runSync {
            let url = try await Self.backupFileURL()
            guard let snapshot = try await Self.readSnapshotIfExists(at: url) else {
                throw ICloudBackupError.missingBackup
            }
            try await self.apply(snapshot)
            try self.updateSyncedState(
                snapshot: snapshot,
                checksum: ICloudBackupSnapshot.checksum(for: snapshot.content)
            )
        }
    }

    private func reconcile() async throws {
        let localContent = try await currentContent()
        let localChecksum = try ICloudBackupSnapshot.checksum(for: localContent)
        let url = try await Self.backupFileURL()

        guard let cloudSnapshot = try await Self.readSnapshotIfExists(at: url) else {
            let snapshot = ICloudBackupSnapshot(
                sourceDeviceID: state.deviceID,
                appVersion: Self.appVersion,
                content: localContent
            )
            try await Self.writeSnapshot(snapshot, to: url)
            try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
            return
        }

        let cloudChecksum = try ICloudBackupSnapshot.checksum(for: cloudSnapshot.content)
        if localChecksum == cloudChecksum {
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        if let lastSyncedChecksum = state.lastSyncedChecksum {
            if localChecksum == lastSyncedChecksum {
                try await apply(cloudSnapshot)
                try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
                return
            }
            if cloudChecksum == lastSyncedChecksum {
                let snapshot = ICloudBackupSnapshot(
                    sourceDeviceID: state.deviceID,
                    appVersion: Self.appVersion,
                    content: localContent
                )
                try await Self.writeSnapshot(snapshot, to: url)
                try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
                return
            }
            throw ICloudBackupError.conflict
        }

        if localContent.profiles.isEmpty, !cloudSnapshot.content.profiles.isEmpty {
            try await apply(cloudSnapshot)
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        let localModifiedAt = await Self.localModifiedDate()
        if let localModifiedAt, cloudSnapshot.createdAt > localModifiedAt {
            try await apply(cloudSnapshot)
            try updateSyncedState(snapshot: cloudSnapshot, checksum: cloudChecksum)
            return
        }

        let snapshot = ICloudBackupSnapshot(
            sourceDeviceID: state.deviceID,
            appVersion: Self.appVersion,
            content: localContent
        )
        try await Self.writeSnapshot(snapshot, to: url)
        try updateSyncedState(snapshot: snapshot, checksum: localChecksum)
    }

    private func runSync(_ operation: @escaping () async throws -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        phase = .syncing
        defer { isSyncing = false }

        do {
            try await operation()
            phase = .ready
            lastError = nil
        } catch {
            setFailure(error)
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
            let fileURLs = [
                URL(fileURLWithPath: FilePath.runtimeSettingsFilePath),
                URL(fileURLWithPath: FilePath.hostSettingsFilePath),
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
