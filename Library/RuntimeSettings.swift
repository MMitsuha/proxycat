import Combine
import Foundation

/// Single source of truth for runtime preferences shared between the host
/// app and the Network Extension. Persists to `settings.json` in the App
/// Group container; the Go core reads the same file directly on every
/// Start / Reload, so toggling a value here propagates without any
/// option-dictionary plumbing.
///
/// Mutating any `@Published` property writes the file and posts a
/// notification. The notification chosen depends on what actually
/// changed:
///   * Log level alone → `runtimeLogLevelDidChange`, routed to a
///     lightweight IPC that calls `log.SetLevel` directly in the
///     extension's mihomo (no `hub.ApplyConfig`).
///   * Anything else (alone or together with log level) →
///     `runtimeSettingsDidChange`, routed to the heavyweight reload
///     path that re-reads settings.json and rebuilds the config.
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

        // Three independent pipes, each describing one concern:
        //
        // 1. Persist the full snapshot whenever any field changes.
        //    Persist from the tuple the publisher hands us, not from
        //    the stored properties: @Published emits in willSet, so
        //    reading self.* here returns the *previous* value and disk
        //    would lag one toggle behind in-memory state. dropFirst
        //    skips the initial replay so we don't re-write what we
        //    just loaded.
        Publishers.CombineLatest($disableExternalController, $logLevel)
            .dropFirst()
            .removeDuplicates(by: { $0 == $1 })
            .sink { disable, level in
                let snapshot = Snapshot(disableExternalController: disable, logLevel: level)
                JSONFileStore.saveOrLog(snapshot, to: FilePath.settingsFilePath, category: "RuntimeSettings")
            }
            .store(in: &bag)

        // 2. Log level changes route to the fast path: apply locally
        //    (host process's mihomo runtime, used by `validate()`) and
        //    post a notification that ExtensionEnvironment turns into
        //    a `setLogLevel` provider message — bypassing
        //    `hub.ApplyConfig`.
        $logLevel
            .dropFirst()
            .removeDuplicates()
            .sink { level in
                LibmihomoBridge.setLogLevel(level)
                NotificationCenter.default.post(
                    name: AppConfiguration.runtimeLogLevelDidChange,
                    object: nil,
                    userInfo: ["level": level]
                )
            }
            .store(in: &bag)

        // 3. Other settings route to the reload path. If a future
        //    change mutates both `disableExternalController` and
        //    `logLevel` in the same cycle, both notifications fire —
        //    that's fine: the reload covers log level via
        //    `applyLogLevel` in `prepareConfig`, and `log.SetLevel` is
        //    idempotent.
        $disableExternalController
            .dropFirst()
            .removeDuplicates()
            .sink { _ in
                NotificationCenter.default.post(
                    name: AppConfiguration.runtimeSettingsDidChange,
                    object: nil
                )
            }
            .store(in: &bag)
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(disableExternalController: false, logLevel: 2)
    }
}
