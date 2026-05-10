import ApplicationLibrary
import Library
import SwiftUI

@main
struct ProxyCatApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground enforcement of the user's saved-log retention
            // policy. Cheap (a directory listing + a few unlinks) and
            // idempotent — covers the case where the user never opens
            // Saved Logs but still wants the on-disk count bounded.
            guard phase == .active else { return }
            FilePath.pruneSavedLogs(
                policy: HostSettingsStore.shared.logRetention
            )
        }
    }
}
