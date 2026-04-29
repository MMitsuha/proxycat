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

    /// Posted whenever the active profile selection changes, or the
    /// active profile's YAML on disk is rewritten. Subscribers (e.g.
    /// `ExtensionEnvironment`) use this to hot-reload the running
    /// tunnel so it picks up the new config without a full restart.
    public static let activeContentDidChange = Notification.Name("io.proxycat.ProfileStore.activeContentDidChange")

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
        let previous = activeProfileID
        activeProfileID = profile.id
        // UUIDs are pure ASCII so utf8 conversion can't fail; the
        // optional-chain in the previous version silently swallowed
        // any disk-write error here.
        let data = Data(profile.id.uuidString.utf8)
        try data.write(to: activePointer, options: .atomic)
        if previous != profile.id {
            NotificationCenter.default.post(name: Self.activeContentDidChange, object: self)
        }
    }

    /// Returns the YAML content for the currently active profile.
    public func loadActiveContent() throws -> String {
        guard let p = active else { throw ProfileError.noProfileSelected }
        return try loadContent(of: p)
    }

    /// Reads the active profile YAML directly off disk without touching
    /// the @MainActor singleton. Safe to call from the Network Extension,
    /// which has no UI but shares the App Group container.
    public nonisolated static func loadActiveContentFromDisk() throws -> String {
        let pointerURL = FilePath.activeProfilePointer
        let raw = try String(contentsOf: pointerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: raw) else {
            throw ProfileError.noProfileSelected
        }
        let indexURL = FilePath.profilesDirectory.appendingPathComponent("index.json")
        let data = try Data(contentsOf: indexURL)
        let profiles = try JSONDecoder().decode([Profile].self, from: data)
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileError.noProfileSelected
        }
        let yamlURL = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        return try String(contentsOf: yamlURL, encoding: .utf8)
    }

    /// Returns the YAML content stored for a specific profile.
    public func loadContent(of profile: Profile) throws -> String {
        let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Overwrites a profile's YAML and bumps its `lastUpdated`.
    public func updateContent(of profile: Profile, yaml: String) throws {
        let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].lastUpdated = .init()
            try persist()
        }
        if profile.id == activeProfileID {
            NotificationCenter.default.post(name: Self.activeContentDidChange, object: self)
        }
    }

    @discardableResult
    public func importYAML(_ content: String, name: String, remoteURL: URL? = nil) throws -> Profile {
        let id = UUID()
        let fileName = id.uuidString + ".yaml"
        let url = FilePath.profilesDirectory.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let profile = Profile(
            id: id,
            name: name,
            fileName: fileName,
            remoteURL: remoteURL,
            lastUpdated: remoteURL != nil ? .init() : nil
        )
        profiles.append(profile)
        try persist()
        if activeProfileID == nil {
            try setActive(profile)
        }
        return profile
    }

    /// Re-downloads `profile.remoteURL`, overwrites the on-disk YAML, and
    /// bumps `lastUpdated`. Throws if the profile has no remote URL.
    public func refreshRemote(_ profile: Profile) async throws {
        guard let url = profile.remoteURL else { throw ProfileError.notRemote }
        let content = try await RemoteProfileFetcher.fetch(url)
        try updateContent(of: profile, yaml: content)
    }

    /// Updates the in-memory profile and persists the index. Caller is
    /// responsible for ensuring the profile id still exists.
    public func rename(_ profile: Profile) throws {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        try persist()
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
    case notRemote
    case invalidURL
    case httpStatus(Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .noProfileSelected: return String(localized: "No profile selected", bundle: .main)
        case .notRemote: return String(localized: "Profile has no remote URL", bundle: .main)
        case .invalidURL: return String(localized: "URL is not valid", bundle: .main)
        case let .httpStatus(code): return String(localized: "Server returned HTTP \(code)", bundle: .main)
        case .emptyResponse: return String(localized: "Server returned an empty body", bundle: .main)
        }
    }
}

/// Fetches subscription YAML from a remote URL.
///
/// Sets a `clash.meta` User-Agent because most subscription providers
/// branch on UA to emit Clash/Mihomo-flavored configs (vs. v2ray, etc.).
public enum RemoteProfileFetcher {
    public static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProfileError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ProfileError.emptyResponse }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
