import Combine
import Foundation
import os

/// Single source of truth for runtime preferences shared between the host
/// app and the Network Extension. Persists to `settings.json` in the App
/// Group container; the Go core reads the same file directly on every
/// Start / Reload, so toggling a value here propagates without any
/// option-dictionary plumbing.
///
/// Mutating any `@Published` property writes the file and posts
/// `AppConfiguration.runtimeSettingsDidChange`. ExtensionEnvironment
/// listens for that notification and asks the running tunnel to reload.
@MainActor
public final class RuntimeSettings: ObservableObject {
    public static let shared = RuntimeSettings()

    @Published public var disableExternalController: Bool
    @Published public var logLevel: Int

    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "RuntimeSettings")
    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = Self.loadFromDisk()
        self.disableExternalController = stored.disableExternalController
        self.logLevel = stored.logLevel

        // dropFirst skips the publisher's "current value" replay so we
        // don't immediately re-write what we just loaded; subsequent
        // changes from a SwiftUI binding flow through persistAndBroadcast.
        //
        // Persist from the tuple the publisher hands us, not from the
        // stored properties: @Published emits in willSet, so reading
        // self.* here returns the *previous* value and disk would lag
        // one toggle behind in-memory state.
        Publishers.CombineLatest($disableExternalController, $logLevel)
            .dropFirst()
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] disable, level in
                self?.persistAndBroadcast(
                    snapshot: Snapshot(disableExternalController: disable, logLevel: level)
                )
            }
            .store(in: &bag)
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(disableExternalController: false, logLevel: 2)
    }

    private static func loadFromDisk() -> Snapshot {
        let path = FilePath.settingsFilePath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .defaults
        }
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? .defaults
    }

    private func persistAndBroadcast(snapshot: Snapshot) {
        do {
            // JSONEncoder produces stable output (no sortedKeys by default
            // but the field order is deterministic per encoder); Go reads
            // the same shape so we don't need a stricter schema here.
            let data = try JSONEncoder().encode(snapshot)
            // Atomic write: a partial file would make Go fall back to
            // defaults mid-toggle, which is worse than a stale file.
            try data.write(to: URL(fileURLWithPath: FilePath.settingsFilePath), options: .atomic)
        } catch {
            Self.logger.error("could not persist settings: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: AppConfiguration.runtimeSettingsDidChange, object: self)
    }
}
