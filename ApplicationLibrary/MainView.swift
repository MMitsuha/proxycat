import Library
import SwiftUI

public struct MainView: View {
    @StateObject private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard
    @State private var importError: String?
    @State private var showImportError = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
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
        .environmentObject(environment)
        .environmentObject(environment.profile)
        .environmentObject(environment.commandClient)
        .environmentObject(ProfileStore.shared)
        // Inject the singletons once so child views don't each instantiate
        // their own @ObservedObject reference. Same observable identity,
        // visible in the dependency graph instead of hidden in each file.
        .environmentObject(RuntimeSettings.shared)
        .environmentObject(HostSettingsStore.shared)
        .environmentObject(DailyUsageStore.shared)
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
        .alert("Import failed", isPresented: $showImportError) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: showImportError) { _, isShowing in
            if !isShowing { importError = nil }
        }
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
            showImportError = true
        }
    }

    enum Tab: Hashable { case dashboard, profiles, logs, settings }
}
