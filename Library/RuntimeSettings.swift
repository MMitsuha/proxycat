import Combine
import Foundation

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

    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = JSONFileStore.load(
            Snapshot.self,
            at: FilePath.settingsFilePath,
            default: .defaults
        )
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

    private func persistAndBroadcast(snapshot: Snapshot) {
        // Always broadcast — the in-memory state has already changed and
        // subscribers must mirror it. The disk write may have failed, in
        // which case we'll re-persist on the next change; that's better
        // than letting the UI desync from RuntimeSettings.shared.
        JSONFileStore.saveOrLog(snapshot, to: FilePath.settingsFilePath, category: "RuntimeSettings")
        NotificationCenter.default.post(name: AppConfiguration.runtimeSettingsDidChange, object: self)
    }
}
