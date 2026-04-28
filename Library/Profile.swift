import Foundation

public struct Profile: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var fileName: String
    public var remoteURL: URL?
    public var lastUpdated: Date?

    public init(id: UUID = .init(), name: String, fileName: String, remoteURL: URL? = nil, lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.lastUpdated = lastUpdated
    }
}

/// File-based profile catalog stored in the shared app-group container.
/// Each profile is one YAML file in `Profiles/` plus a metadata index at
/// `Profiles/index.json`. No CoreData / GRDB dependency to keep the binary
/// small.
@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public private(set) var profiles: [Profile] = []
    @Published public var activeProfileID: UUID?

    private let indexURL: URL = FilePath.profilesDirectory.appendingPathComponent("index.json")
    private let activePointer: URL = FilePath.activeProfilePointer

    private init() {
        reload()
    }

    public func reload() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        if let data = try? Data(contentsOf: activePointer),
           let str = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id
        }
    }

    public var active: Profile? {
        guard let id = activeProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == id })
    }

    public func setActive(_ profile: Profile) throws {
        activeProfileID = profile.id
        try profile.id.uuidString.data(using: .utf8)?.write(to: activePointer, options: .atomic)
    }

    /// Returns the YAML content for the currently active profile.
    public func loadActiveContent() throws -> String {
        guard let p = active else { throw ProfileError.noProfileSelected }
        let url = FilePath.profilesDirectory.appendingPathComponent(p.fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @discardableResult
    public func importYAML(_ content: String, name: String) throws -> Profile {
        let id = UUID()
        let fileName = id.uuidString + ".yaml"
        let url = FilePath.profilesDirectory.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let profile = Profile(id: id, name: name, fileName: fileName)
        profiles.append(profile)
        try persist()
        if activeProfileID == nil {
            try setActive(profile)
        }
        return profile
    }

    public func delete(_ profile: Profile) throws {
        let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        try? FileManager.default.removeItem(at: url)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles.first?.id
            if let next = profiles.first {
                try setActive(next)
            } else {
                try? FileManager.default.removeItem(at: activePointer)
            }
        }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: indexURL, options: .atomic)
    }
}

public enum ProfileError: LocalizedError {
    case noProfileSelected
    public var errorDescription: String? {
        switch self {
        case .noProfileSelected: return "No profile selected"
        }
    }
}
