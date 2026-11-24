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

public struct ValidatedProfileYAML: Equatable, Sendable {
    public let content: String

    /// Internal so only the validation pipeline inside Library can mint
    /// the token; callers in the app layer must go through
    /// `ProfileStore.validateYAML` / `importYAML`.
    init(content: String) {
        self.content = content
    }
}

public enum ProfileError: LocalizedError {
    case notRemote
    case invalidURL
    case httpStatus(Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .notRemote: return String(localized: "Profile has no remote URL", bundle: .main)
        case .invalidURL: return String(localized: "URL is not valid", bundle: .main)
        case let .httpStatus(code): return String(localized: "Server returned HTTP \(code)", bundle: .main)
        case .emptyResponse: return String(localized: "Server returned an empty body", bundle: .main)
        }
    }
}

public enum ProfileRestoreError: LocalizedError, Equatable {
    case duplicateProfileID(UUID)
    case duplicateFileName(String)
    case invalidFileName(String)
    case missingContent(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateProfileID(id):
            return String(localized: "Backup contains duplicate profile id \(id.uuidString).", bundle: .main)
        case let .duplicateFileName(fileName):
            return String(localized: "Backup contains duplicate profile file \(fileName).", bundle: .main)
        case let .invalidFileName(fileName):
            return String(localized: "Backup contains invalid profile file \(fileName).", bundle: .main)
        case let .missingContent(name):
            return String(localized: "Backup is missing YAML for \(name).", bundle: .main)
        }
    }
}
