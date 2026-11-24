import CryptoKit
import Foundation

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
