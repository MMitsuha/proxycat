import Foundation
import Observation

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

public struct ValidatedProfileYAML: Equatable, Sendable {
    public let content: String

    fileprivate init(content: String) {
        self.content = content
    }
}

/// File-based profile catalog stored in the shared app-group container.
/// Each profile is one YAML file in `Profiles/` plus a metadata index at
/// `Profiles/index.json`. The active profile UUID lives in
/// `runtime_settings.json` (see `RuntimeSettings`) — this store mirrors
/// it for SwiftUI observation but doesn't own the persistence. No
/// CoreData / GRDB dependency to keep the binary small.
@MainActor @Observable
public final class ProfileStore {
    public static let shared = ProfileStore()

    /// Posted whenever the active profile selection changes, or the
    /// active profile's YAML on disk is rewritten. Picked up by
    /// `SettingsChangeCoordinator` (composed inside
    /// `ExtensionEnvironment`), which fires the gRPC `Reload` RPC so
    /// the running tunnel hot-applies the new config without a full
    /// restart.
    public static let activeContentDidChange = Notification.Name("io.proxycat.ProfileStore.activeContentDidChange")

    public private(set) var profiles: [Profile] = []
    /// Mirror of `RuntimeSettings.shared.activeProfileID`. Read-only
    /// from outside; mutate exclusively through `setActive` / `delete`
    /// so RuntimeSettings (the cross-process source of truth) stays
    /// in sync. A SwiftUI binding writing this directly would silently
    /// lose persistence.
    public private(set) var activeProfileID: UUID?

    @ObservationIgnored private let indexURL: URL = URL(fileURLWithPath: FilePath.profileIndexFilePath)

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
        // RuntimeSettings is the single source of truth across host /
        // extension. Repair it when the stored id is missing from the
        // index; otherwise SwiftUI would show the first profile as
        // selected while the Go core still reads the stale id from disk.
        let storedID = RuntimeSettings.shared.activeProfileID
        let repairedID = Self.repairedActiveProfileID(profiles: profiles, storedID: storedID)
        activeProfileID = repairedID
        if repairedID != storedID {
            RuntimeSettings.shared.activeProfileID = repairedID
        }
    }

    public var active: Profile? {
        guard let id = activeProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == id })
    }

    public func setActive(_ profile: Profile) throws {
        let previous = activeProfileID
        activeProfileID = profile.id
        // RuntimeSettings persists to runtime_settings.json; the Go
        // core picks up the new id on the next gRPC Reload. Only post
        // activeContentDidChange when the selection actually changed —
        // re-selecting the same profile is a no-op for the tunnel.
        RuntimeSettings.shared.activeProfileID = profile.id
        if previous != profile.id {
            NotificationCenter.default.post(name: Self.activeContentDidChange, object: self)
        }
    }

    /// Returns the YAML content for the currently active profile.
    public func loadActiveContent() throws -> String {
        guard let p = active else { throw ProfileError.noProfileSelected }
        return try loadContent(of: p)
    }

    /// Returns the YAML content stored for a specific profile.
    public func loadContent(of profile: Profile) throws -> String {
        let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Overwrites a profile's YAML and bumps its `lastUpdated`. If
    /// `name` is provided and differs from the current entry, renames
    /// in the same persist so the editor's "save YAML + rename" path
    /// can't half-succeed.
    ///
    /// Validates with mihomo's parser before writing so callers like
    /// `refreshRemote` can't replace a working profile with an
    /// unparseable response from a flaky subscription server.
    ///
    /// The YAML write itself runs on a detached task: profile YAMLs can
    /// be 100KB–1MB for large rule sets, and a synchronous write on the
    /// MainActor would visibly hitch the editor's save action.
    public func updateContent(of profile: Profile, yaml: String, name: String? = nil) async throws {
        let validated = try await Self.validateYAML(yaml)
        try await updateContent(of: profile, validatedYAML: validated, name: name)
    }

    public func updateContent(of profile: Profile, validatedYAML: ValidatedProfileYAML, name: String? = nil) async throws {
        let fileName = profile.fileName
        try await Self.writeYAML(validatedYAML.content, fileName: fileName)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].lastUpdated = .init()
            if let name, !name.isEmpty, name != profiles[idx].name {
                profiles[idx].name = name
            }
            try persist()
        }
        if profile.id == activeProfileID {
            NotificationCenter.default.post(name: Self.activeContentDidChange, object: self)
        }
    }

    /// Persists a new profile with the given YAML content. Validates with
    /// mihomo's parser before writing so file/URL/share-sheet ingress
    /// paths can't seed the catalog with unparseable YAML, regardless of
    /// whether the caller validated interactively first.
    @discardableResult
    public func importYAML(_ content: String, name: String, remoteURL: URL? = nil) async throws -> Profile {
        let validated = try await Self.validateYAML(content)
        return try await importYAML(validated, name: name, remoteURL: remoteURL)
    }

    @discardableResult
    public func importYAML(_ validatedYAML: ValidatedProfileYAML, name: String, remoteURL: URL? = nil) async throws -> Profile {
        let id = UUID()
        let fileName = id.uuidString + ".yaml"
        try await Self.writeYAML(validatedYAML.content, fileName: fileName)

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

    /// Downloads, validates, and imports a remote profile in one pipeline.
    /// The validated token is passed directly into `importYAML` so the same
    /// fetched YAML is never parsed twice before being written.
    @discardableResult
    public func importRemote(from url: URL, name: String) async throws -> Profile {
        let validated = try await Self.fetchAndValidateRemote(url)
        return try await importYAML(validated, name: name, remoteURL: url)
    }

    /// Imports a YAML profile from a file URL, handling iOS security-scoped
    /// resource access. Used by both the in-app `.fileImporter` and the
    /// share-sheet `.onOpenURL` entry point.
    ///
    /// `startAccessingSecurityScopedResource()` returning `false` is not
    /// treated as fatal — iOS reports `false` for URLs already accessible
    /// to the app (e.g. files inside the app's own container). Letting
    /// `String(contentsOf:)` decide produces a more accurate error.
    @discardableResult
    public func importYAML(from url: URL) async throws -> Profile {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let content = try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
        let name = url.deletingPathExtension().lastPathComponent
        return try await importYAML(content, name: name)
    }

    /// Re-downloads `profile.remoteURL`, overwrites the on-disk YAML, and
    /// bumps `lastUpdated`. Throws if the profile has no remote URL.
    public func refreshRemote(_ profile: Profile) async throws {
        guard let url = profile.remoteURL else { throw ProfileError.notRemote }
        let validated = try await Self.fetchAndValidateRemote(url)
        try await updateContent(of: profile, validatedYAML: validated)
    }

    /// Writes a YAML payload to the profiles directory off the MainActor.
    /// Centralizes the disk-write pattern so importYAML and updateContent
    /// share one I/O path.
    private static func writeYAML(_ content: String, fileName: String) async throws {
        let url = FilePath.profilesDirectory.appendingPathComponent(fileName)
        try await Task.detached(priority: .userInitiated) {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    public nonisolated static func validateYAML(_ content: String) async throws -> ValidatedProfileYAML {
        try await LibmihomoBridge.validateAsync(yaml: Data(content.utf8))
        return ValidatedProfileYAML(content: content)
    }

    private nonisolated static func fetchAndValidateRemote(_ url: URL) async throws -> ValidatedProfileYAML {
        let content = try await RemoteProfileFetcher.fetch(url)
        return try await validateYAML(content)
    }

    public func delete(_ profile: Profile) throws {
        let url = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        try? FileManager.default.removeItem(at: url)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            if let next = profiles.first {
                // Do NOT pre-set activeProfileID here. setActive needs to
                // see the old (deleted) id as `previous` so that
                // previous != next.id and it posts activeContentDidChange.
                // Pre-setting silently suppresses the reload notification,
                // leaving the running tunnel serving the deleted config.
                try setActive(next)
            } else {
                activeProfileID = nil
                RuntimeSettings.shared.activeProfileID = nil
                // Tunnel may be running with the now-deleted profile.
                // Posting the same notification ExtensionEnvironment
                // listens for makes it surface a reload error rather
                // than silently keep serving the old in-memory config.
                NotificationCenter.default.post(name: Self.activeContentDidChange, object: self)
            }
        }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: indexURL, options: .atomic)
    }

    nonisolated static func repairedActiveProfileID(profiles: [Profile], storedID: UUID?) -> UUID? {
        if let storedID, profiles.contains(where: { $0.id == storedID }) {
            return storedID
        }
        return profiles.first?.id
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
