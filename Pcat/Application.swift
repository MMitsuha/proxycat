import ApplicationLibrary
import Library
import SwiftUI

@main
struct ProxyCatApp: App {
    private static let logger = ProxyCatLogger(subsystem: "io.proxycat.Pcat", category: "App")

    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let path = try ProxyCatLogPersistence.shared.start(role: .hostApp)
            Self.logger.info("proxycat host session log = \(path)")
        } catch {
            Self.logger.warning("could not open proxycat host session log: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Foreground enforcement of the user's saved-log retention
                // policy. Cheap (a directory listing + a few unlinks) and
                // idempotent — covers the case where the user never opens
                // Saved Logs but still wants the on-disk count bounded.
                FilePath.pruneSavedLogs(
                    policy: HostSettingsStore.shared.logRetention
                )
            } else {
                ProxyCatLogPersistence.shared.flush()
            }
        }
    }
}
