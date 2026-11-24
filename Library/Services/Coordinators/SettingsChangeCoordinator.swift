import Foundation

// MARK: - Settings change

/// Observes the two notifications that should trigger a tunnel reload:
/// active profile content changed, runtime settings changed. Errors
/// from the reload bubble up via `onError`.
///
/// Dispatches to the extension's mihomo via the gRPC `CommandClient`
/// rather than `NETunnelProviderSession.sendProviderMessage` — one
/// channel for both streaming events and unary commands. The extension
/// has no opinion of its own; runtime_settings.json is the source of
/// truth, and the gRPC RPC is just a nudge to re-read it.
///
/// Log level is intentionally NOT handled here: it is a host-side
/// display filter (the extension always emits every event), so a
/// change to `RuntimeSettings.logLevel` reaches the Logs tab via the
/// shared @Observable and never needs to cross IPC.
@MainActor
public final class SettingsChangeCoordinator {
    public var onError: ((String) -> Void)?

    private let commandClient: CommandClient
    private var tasks: [Task<Void, Never>] = []

    public init(commandClient: CommandClient) {
        self.commandClient = commandClient
    }

    public func start() {
        for task in tasks { task.cancel() }
        tasks.removeAll()

        let center = NotificationCenter.default

        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: ProfileStore.activeContentDidChange) {
                await self?.reloadIfConnected()
            }
        })

        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: AppConfiguration.runtimeSettingsDidChange) {
                await self?.reloadIfConnected()
            }
        })
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    private func reloadIfConnected() async {
        guard commandClient.isConnected else { return }
        do {
            try await commandClient.reload()
        } catch {
            onError?(error.localizedDescription)
        }
    }
}
