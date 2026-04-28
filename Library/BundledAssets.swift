import Foundation
import os

/// A geo database, external-UI bundle, or other asset that ships
/// embedded inside the Library framework and gets installed into the
/// App Group working directory on first run.
public struct BundledAsset: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case geo
        case externalUI
    }

    /// Path of the asset relative to `FilePath.workingDirectory` —
    /// also acts as a stable identifier and the entry name to skip
    /// during Clear Cache.
    public let id: String
    public let kind: Kind
    public let displayName: String
    public let bundleURL: URL
    public let bundledSize: Int64
    public let isDirectory: Bool

    public var destinationURL: URL {
        FilePath.workingDirectory.appendingPathComponent(id, isDirectory: isDirectory)
    }
}

/// Discovers, installs, and protects compile-time bundled assets.
///
/// Layout inside the project's `BundledAssets/` folder reference:
///   - `geo/<file>`  — single files copied to `<workingDir>/<file>`
///   - `ui/`         — entire directory copied to `<workingDir>/ui/`
/// Anything else is reported as `.other` so it still shows up in
/// Settings even if it doesn't fit the two known kinds.
public enum BundledAssets {
    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "BundledAssets")

    private final class Marker {}

    /// Root URL of the bundled assets folder reference inside the
    /// Library framework, or nil when nothing was bundled.
    private static let assetsRoot: URL? = {
        let frameworkBundle = Bundle(for: Marker.self)
        if let url = frameworkBundle.url(forResource: "BundledAssets", withExtension: nil) {
            return url
        }
        let candidate = frameworkBundle.bundleURL.appendingPathComponent("BundledAssets", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return nil
    }()

    /// All assets discovered in the framework bundle. Resolved once
    /// since the bundle is immutable for the life of the process.
    public static let all: [BundledAsset] = discover()

    /// Top-level entry names within `workingDirectory` that
    /// `FilePath.clearCache()` must skip and `cacheSize()` must not
    /// count. Exposes only the leading path component (e.g. "ui",
    /// "geoip.dat") so any nested files under a protected directory
    /// are also preserved.
    public static var protectedTopLevelNames: Set<String> {
        Set(all.map { ($0.id as NSString).pathComponents.first ?? $0.id })
    }

    /// Copy missing or out-of-date bundled assets into the working
    /// directory. Idempotent and safe to call from both the host app
    /// and the Network Extension; returns the IDs that were actually
    /// (re)written this call.
    @discardableResult
    public static func installIfNeeded() -> [String] {
        guard !all.isEmpty else { return [] }
        let fm = FileManager.default
        var installed: [String] = []
        for asset in all {
            let dest = asset.destinationURL
            do {
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if asset.isDirectory {
                    if fm.fileExists(atPath: dest.path) { continue }
                    try fm.copyItem(at: asset.bundleURL, to: dest)
                } else {
                    if let values = try? dest.resourceValues(forKeys: [.fileSizeKey]),
                       Int64(values.fileSize ?? 0) == asset.bundledSize
                    {
                        continue
                    }
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.copyItem(at: asset.bundleURL, to: dest)
                }
                installed.append(asset.id)
            } catch {
                logger.error("install \(asset.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !installed.isEmpty {
            logger.info("installed bundled assets: \(installed.joined(separator: ", "), privacy: .public)")
        }
        return installed
    }

    private static func discover() -> [BundledAsset] {
        guard let root = assetsRoot else { return [] }
        var assets: [BundledAsset] = []

        // Geo files: each regular file under geo/ becomes its own asset.
        let geoDir = root.appendingPathComponent("geo", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: geoDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true
                else { continue }
                assets.append(BundledAsset(
                    id: entry.lastPathComponent,
                    kind: .geo,
                    displayName: entry.lastPathComponent,
                    bundleURL: entry,
                    bundledSize: Int64(values.fileSize ?? 0),
                    isDirectory: false
                ))
            }
        }

        // External UI: the entire ui/ directory becomes a single asset
        // mapped to <workingDir>/ui — the path mihomo's `external-ui`
        // option points at when set to `./ui`.
        let uiDir = root.appendingPathComponent("ui", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: uiDir.path, isDirectory: &isDir),
           isDir.boolValue,
           hasVisibleContents(uiDir)
        {
            assets.append(BundledAsset(
                id: "ui",
                kind: .externalUI,
                displayName: "External UI",
                bundleURL: uiDir,
                bundledSize: directorySize(uiDir),
                isDirectory: true
            ))
        }

        return assets
    }

    private static func hasVisibleContents(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return !entries.isEmpty
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in enumerator {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true
            else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}
