import CryptoKit
import Foundation
import Observation

public struct ICloudBackupProfile: Codable, Equatable, Sendable {
    public var profile: Profile
    public var yaml: String

    public init(profile: Profile, yaml: String) {
        self.profile = profile
        self.yaml = yaml
    }
}

public struct ICloudBackupContent: Codable, Equatable, Sendable {
    public var runtimeSettings: RuntimeSettings.Snapshot
    public var hostSettings: HostSettings
    public var profiles: [ICloudBackupProfile]

    public init(
        runtimeSettings: RuntimeSettings.Snapshot,
        hostSettings: HostSettings,
        profiles: [ICloudBackupProfile]
    ) {
        self.runtimeSettings = runtimeSettings
        self.hostSettings = hostSettings
        self.profiles = profiles
    }
}

public struct ICloudBackupSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var sourceDeviceID: UUID
    public var appVersion: String?
    public var content: ICloudBackupContent

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDeviceID: UUID,
        appVersion: String?,
        content: ICloudBackupContent
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.sourceDeviceID = sourceDeviceID
        self.appVersion = appVersion
        self.content = content
    }

    public static func make(
        profiles: [Profile],
        contentsByID: [UUID: String],
        runtimeSettings: RuntimeSettings.Snapshot,
        hostSettings: HostSettings,
        sourceDeviceID: UUID,
        appVersion: String?,
        createdAt: Date = Date()
    ) throws -> ICloudBackupSnapshot {
        let restoredProfiles = try ProfileStore.validatedRestoreProfiles(profiles, contentsByID: contentsByID)
        let entries = try restoredProfiles.map { profile in
            guard let yaml = contentsByID[profile.id] else {
                throw ProfileRestoreError.missingContent(profile.name)
            }
            return ICloudBackupProfile(profile: profile, yaml: yaml)
        }
        return ICloudBackupSnapshot(
            createdAt: createdAt,
            sourceDeviceID: sourceDeviceID,
            appVersion: appVersion,
            content: ICloudBackupContent(
                runtimeSettings: runtimeSettings,
                hostSettings: hostSettings,
                profiles: entries
            )
        )
    }

    public static func checksum(for content: ICloudBackupContent) throws -> String {
        let data = try canonicalEncoder.encode(content)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static var fileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

public struct ICloudBackupSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var sourceDeviceID: UUID
    public var profileCount: Int
    public var appVersion: String?

    public init(snapshot: ICloudBackupSnapshot) {
        self.id = snapshot.id
        self.createdAt = snapshot.createdAt
        self.sourceDeviceID = snapshot.sourceDeviceID
        self.profileCount = snapshot.content.profiles.count
        self.appVersion = snapshot.appVersion
    }
}

public enum ICloudBackupPhase: Equatable, Sendable {
    case disabled
    case unavailable
    case ready
    case syncing
    case conflict
    case error(String)
}

public enum ICloudBackupError: LocalizedError, Equatable {
    case unavailable
    case missingBackup
    case unsupportedVersion(Int)
    case conflict

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive for ProxyCat.", bundle: .main)
        case .missingBackup:
            return String(localized: "No iCloud backup was found.", bundle: .main)
        case let .unsupportedVersion(version):
            return String(localized: "This iCloud backup uses unsupported schema version \(version).", bundle: .main)
        case .conflict:
            return String(localized: "Both local data and the iCloud backup changed. Choose Back Up Now or Restore from iCloud.", bundle: .main)
        }
    }
}

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
            phase = isSyncing ? .syncing : .ready
            lastError = nil
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
        return ICloudBackupContent(
            runtimeSettings: RuntimeSettings.shared.snapshot,
            hostSettings: HostSettingsStore.shared.snapshot,
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
        HostSettingsStore.shared.replace(with: snapshot.content.hostSettings)
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
                let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
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
