import Foundation
import Library

/// Copies a profile YAML into a temporary, sanitized filename so the
/// system share sheet never exposes the UUID-named on-disk file.
struct ProfileShareItem: Identifiable {
    let id = UUID()
    let url: URL

    init(_ profile: Profile) throws {
        let source = FilePath.profileURL(named: profile.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ProfileShareError.missingFile
        }

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxycat-profile-share", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let destination = exportDirectory.appendingPathComponent(Self.fileName(for: profile))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        url = destination
    }

    private static func fileName(for profile: Profile) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = profile.name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "profile" : sanitized
        return base.hasSuffix(".yaml") || base.hasSuffix(".yml") ? base : "\(base).yaml"
    }
}

enum ProfileShareError: LocalizedError {
    case missingFile

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return String(localized: "Profile file is missing.", bundle: .main)
        }
    }
}
