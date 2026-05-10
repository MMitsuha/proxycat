import Library
import SwiftUI

public struct MainView: View {
    @State private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard
    @State private var importError: String?
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        @Bindable var environment = environment
        return TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("Dashboard", systemImage: "speedometer") }
            .tag(Tab.dashboard)

            NavigationStack {
                ProfileListView()
            }
            .tabItem { Label("Profiles", systemImage: "doc.text") }
            .tag(Tab.profiles)

            NavigationStack {
                LogView()
            }
            .tabItem { Label("Logs", systemImage: "text.alignleft") }
            .tag(Tab.logs)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .environment(environment)
        .environment(environment.profile)
        .environment(environment.commandClient)
        .environment(ProfileStore.shared)
        // Inject the singletons once so child views don't each instantiate
        // their own reference. .environment(_:) propagates the same
        // @Observable instance to descendants.
        .environment(RuntimeSettings.shared)
        .environment(HostSettingsStore.shared)
        .environment(DailyUsageStore.shared)
        .task { await environment.bootstrap() }
        .onOpenURL { url in
            Task { await handleIncomingFile(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist any buffered daily-usage deltas before the system
            // freezes or kills us. Other stores write synchronously on
            // mutation, so they don't need a flush hook.
            if phase != .active {
                DailyUsageStore.shared.flushNow()
            }
        }
        .errorAlert($importError, title: "Import failed")
        // Hosted at TabView level so a reload failure triggered from
        // Settings, Logs, or any other tab still surfaces — settings
        // changes go through SettingsChangeCoordinator regardless of
        // which tab the user is on.
        .errorAlert($environment.reloadError, title: "Reload failed")
    }

    /// Imports a YAML file delivered by the system (Share sheet, Open With,
    /// AirDrop, etc.) and switches to the Profiles tab on success. Errors
    /// surface in the alert and leave the current tab untouched so the
    /// user is not yanked away from where they were.
    @MainActor
    private func handleIncomingFile(_ url: URL) async {
        do {
            _ = try await ProfileStore.shared.importYAML(from: url)
            selection = .profiles
        } catch {
            importError = error.localizedDescription
        }
    }

    enum Tab: Hashable { case dashboard, profiles, logs, settings }
}
