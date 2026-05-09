import Foundation
import Observation

/// Single source of truth for runtime preferences shared between the
/// host app and the Network Extension. Persists to
/// `runtime_settings.json` in the App Group container; the Go core
/// reads the same file directly on every Start / Reload, so toggling a
/// value here propagates without any option-dictionary plumbing.
///
/// Holds three fields:
///   * `activeProfileID` — UUID of the currently selected profile.
///     Mutated through `ProfileStore.setActive`, which also posts
///     `activeContentDidChange` so the host UI can react. Setting the
///     property here only persists; ProfileStore owns the user-facing
///     "switched profile" notification.
///   * `disableExternalController` — toggling posts
///     `runtimeSettingsDidChange`, routed to the heavyweight reload
///     path (gRPC Reload RPC) that re-reads runtime_settings.json and
///     rebuilds the config.
///   * `logLevel` — toggling posts `runtimeLogLevelDidChange`, routed
///     to the lightweight gRPC SetLogLevel RPC that calls
///     `log.SetLevel` directly in the extension's mihomo (no
///     `hub.ApplyConfig`).
@MainActor @Observable
public final class RuntimeSettings {
    public static let shared = RuntimeSettings()

    public var activeProfileID: UUID? {
        didSet {
            guard loaded, activeProfileID != oldValue else { return }
            persist()
            // Asymmetric vs the other properties: ProfileStore.setActive
            // is the user-facing entry point and posts
            // activeContentDidChange itself, so we don't double-notify
            // here. Direct writes (e.g. ProfileStore.delete clearing the
            // selection) post the notification at the call site too.
        }
    }

    public var disableExternalController: Bool {
        didSet {
            guard loaded, disableExternalController != oldValue else { return }
            persist()
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeSettingsDidChange,
                object: nil
            )
        }
    }

    public var logLevel: Int {
        didSet {
            guard loaded, logLevel != oldValue else { return }
            persist()
            LibmihomoBridge.setLogLevel(logLevel)
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeLogLevelDidChange,
                object: nil,
                userInfo: ["level": logLevel]
            )
        }
    }

    @ObservationIgnored private var loaded = false

    private init() {
        let stored = JSONFileStore.load(
            Snapshot.self,
            at: FilePath.runtimeSettingsFilePath,
            default: .defaults
        )
        self.activeProfileID = stored.activeProfileID
        self.disableExternalController = stored.disableExternalController
        self.logLevel = stored.logLevel
        self.loaded = true
    }

    private func persist() {
        let snapshot = Snapshot(
            activeProfileID: activeProfileID,
            disableExternalController: disableExternalController,
            logLevel: logLevel
        )
        JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.runtimeSettingsFilePath,
            category: "RuntimeSettings"
        )
    }

    /// Reads the active profile YAML directly off disk without touching
    /// the @MainActor singleton. Mirrors what the Go core's
    /// `loadActiveYAML` does (libmihomo/binding.go) so test fixtures
    /// and any other disk-only consumer stay in lock-step with the
    /// extension's view of "what's active".
    public nonisolated static func loadActiveProfileContent() throws -> String {
        let snapshotData = try Data(contentsOf: URL(fileURLWithPath: FilePath.runtimeSettingsFilePath))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: snapshotData)
        guard let id = snapshot.activeProfileID else {
            throw ProfileError.noProfileSelected
        }
        let indexURL = FilePath.profilesDirectory.appendingPathComponent(AppConfiguration.profileIndexFileName)
        let indexData = try Data(contentsOf: indexURL)
        let profiles = try JSONDecoder().decode([Profile].self, from: indexData)
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileError.noProfileSelected
        }
        let yamlURL = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
        return try String(contentsOf: yamlURL, encoding: .utf8)
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var activeProfileID: UUID?
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(
            activeProfileID: nil,
            disableExternalController: false,
            logLevel: 2
        )
    }
}
