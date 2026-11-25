import Library
import SwiftUI
import UIKit

public struct MainView: View {
    @State private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard
    @State private var importError: String?
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        @Bindable var bindableEnvironment = environment
        return TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
            }
            .tabItem { tabLabel(.dashboard) }
            .tag(Tab.dashboard)
            .accessibilityIdentifier("screen.dashboard")

            NavigationStack {
                ProfileListView()
            }
            .tabItem { tabLabel(.profiles) }
            .tag(Tab.profiles)
            .accessibilityIdentifier("screen.profiles")

            NavigationStack {
                LogView()
            }
            .tabItem { tabLabel(.logs) }
            .tag(Tab.logs)
            .accessibilityIdentifier("screen.logs")

            NavigationStack {
                SettingsView()
            }
            .tabItem { tabLabel(.settings) }
            .tag(Tab.settings)
            .accessibilityIdentifier("screen.settings")
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
        .environment(ICloudBackupStore.shared)
        .task {
            environment.commandClient.setAppActive(scenePhase == .active)
            environment.webConfig.setAppActive(scenePhase == .active)
            await environment.bootstrap()
            ICloudBackupStore.shared.startAutoSync()
            UIApplication.shared.isIdleTimerDisabled = environment.webConfig.state.isRunning
        }
        // The LAN editor is only reachable while the host app is awake.
        // Keep the screen on while the server is running so auto-lock does
        // not silently tear the browser session down.
        .onChange(of: environment.webConfig.state) { _, state in
            UIApplication.shared.isIdleTimerDisabled = state.isRunning
        }
        .onOpenURL { url in
            Task { await handleIncomingFile(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist any buffered daily-usage deltas before the system
            // freezes or kills us. Other stores write synchronously on
            // mutation, so they don't need a flush hook.
            environment.commandClient.setAppActive(phase == .active)
            environment.webConfig.setAppActive(phase == .active)
            if phase == .active {
                ICloudBackupStore.shared.startAutoSync()
            } else {
                DailyUsageStore.shared.flushNow()
            }
        }
        .errorAlert($importError, title: "Import failed")
        // Hosted at TabView level so a reload failure triggered from
        // Settings, Logs, or any other tab still surfaces — settings
        // changes go through SettingsChangeCoordinator regardless of
        // which tab the user is on.
        .errorAlert($bindableEnvironment.reloadError, title: "Reload failed")
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

    @ViewBuilder
    private func tabLabel(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
            .accessibilityIdentifier(tab.accessibilityID)
    }

    enum Tab: Hashable {
        case dashboard
        case profiles
        case logs
        case settings

        var title: LocalizedStringKey {
            switch self {
            case .dashboard: return "Dashboard"
            case .profiles: return "Profiles"
            case .logs: return "Logs"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .dashboard: return "speedometer"
            case .profiles: return "doc.text"
            case .logs: return "text.alignleft"
            case .settings: return "gearshape"
            }
        }

        var accessibilityID: String {
            switch self {
            case .dashboard: return "tab.dashboard"
            case .profiles: return "tab.profiles"
            case .logs: return "tab.logs"
            case .settings: return "tab.settings"
            }
        }
    }
}
