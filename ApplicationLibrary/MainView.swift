import Library
import SwiftUI

public struct MainView: View {
    @StateObject private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard
    @State private var importError: String?

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
        .task { await environment.bootstrap() }
        .onOpenURL { url in handleIncomingFile(url) }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Imports a YAML file delivered by the system (Share sheet, Open With,
    /// AirDrop, etc.) and switches to the Profiles tab on success. Errors
    /// surface in the alert and leave the current tab untouched so the
    /// user is not yanked away from where they were.
    private func handleIncomingFile(_ url: URL) {
        do {
            _ = try ProfileStore.shared.importYAML(from: url)
            selection = .profiles
        } catch {
            importError = error.localizedDescription
        }
    }

    enum Tab: Hashable { case dashboard, profiles, logs, settings }
}
