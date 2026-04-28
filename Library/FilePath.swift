import Foundation

public enum FilePath {
    /// Container shared between the host app and the Network Extension.
    public static var sharedDirectory: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupID
        ) else {
            preconditionFailure("App group container missing — check entitlements")
        }
        return url
    }

    public static var profilesDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var workingDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Working", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var cacheDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where the active profile selection (just a filename) is persisted.
    public static var activeProfilePointer: URL {
        sharedDirectory.appendingPathComponent("active-profile")
    }
}
