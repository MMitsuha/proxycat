import Darwin
import Foundation

/// A geo database or external-UI bundle that ships embedded inside
/// the Library framework and gets installed into the App Group
/// working directory on first run.
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
///   - `default-profile.yaml` — template read directly by the profile editor
/// Anything outside those roots is not installed by `installIfNeeded()` —
/// extend `discover()` and `BundledAsset.Kind` for a new installable family.
public enum BundledAssets {
    private static let logger = ProxyCatLogger(subsystem: "io.proxycat.Library", category: "BundledAssets")

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
    /// `StorageMaintenance.clearCache()` must skip and `cacheSize()` must not
    /// count. Exposes only the leading path component (e.g. "ui",
    /// "geoip.dat") so any nested files under a protected directory
    /// are also preserved.
    public static var protectedTopLevelNames: Set<String> {
        Set(all.map { ($0.id as NSString).pathComponents.first ?? $0.id })
    }

    /// YAML template used by the profile editor's "New / Paste YAML"
    /// flow. This file is a framework resource (not a working-directory
    /// asset), so it is read directly from the bundle and never pruned
    /// by Clear Cache.
    public static var defaultProfileYAML: String? {
        guard let url = assetsRoot?.appendingPathComponent("default-profile.yaml") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
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
                let didInstall = if asset.isDirectory {
                    try installDirectory(asset, at: dest, fm: fm)
                } else {
                    try installFile(asset, at: dest, fm: fm)
                }
                if didInstall {
                    installed.append(asset.id)
                }
            } catch {
                logger.error("install \(asset.id) failed: \(error.localizedDescription)")
            }
        }
        if !installed.isEmpty {
            logger.info("installed bundled assets: \(installed.joined(separator: ", "))")
        }
        return installed
    }

    /// Copy through a sibling temp path, then `rename(2)` into place.
    /// Rename is atomic and replaces an existing regular file, so the
    /// host app and Network Extension can install concurrently without
    /// ever exposing a half-copied asset (or corrupting one another).
    private static func installFile(_ asset: BundledAsset, at dest: URL, fm: FileManager) throws -> Bool {
        if let values = try? dest.resourceValues(forKeys: [.fileSizeKey]),
           Int64(values.fileSize ?? 0) == asset.bundledSize
        {
            return false
        }
        let temp = temporaryInstallURL(for: dest)
        try fm.copyItem(at: asset.bundleURL, to: temp)
        do {
            guard rename(temp.path, dest.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return true
    }

    /// Directories are installed whole. If another process won the race,
    /// `rename` reports EEXIST / ENOTEMPTY and we keep the winner.
    private static func installDirectory(_ asset: BundledAsset, at dest: URL, fm: FileManager) throws -> Bool {
        if fm.fileExists(atPath: dest.path) { return false }
        let temp = temporaryInstallURL(for: dest)
        try fm.copyItem(at: asset.bundleURL, to: temp)
        if rename(temp.path, dest.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            if code == EEXIST || code == ENOTEMPTY {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return true
    }

    private static func temporaryInstallURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
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
