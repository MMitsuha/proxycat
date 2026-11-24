import Foundation

// MARK: - Traffic

/// Forwards every Status frame the command client publishes into the
/// daily-usage aggregator. Drops the initial replayed `.zero` (which
/// would otherwise look like an extension counter reset) and dedupes
/// identical idle ticks.
@MainActor
public final class TrafficCoordinator {
    private let commandClient: CommandClient
    private let usageStore: DailyUsageStore
    private var observationTask: Task<Void, Never>?

    public init(commandClient: CommandClient, usageStore: DailyUsageStore) {
        self.commandClient = commandClient
        self.usageStore = usageStore
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var last: TrafficSnapshot?
            // dropFirst skips the initial .zero replay (otherwise the
            // very first frame would look like a counter reset). Manual
            // dedupe replicates the previous removeDuplicates() arm.
            for await snapshot in Observed.values({ self.commandClient.traffic }).dropFirst() {
                if snapshot == last { continue }
                last = snapshot
                self.usageStore.record(snapshot: snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
