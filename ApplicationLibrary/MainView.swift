import Library
import SwiftUI

public struct MainView: View {
    @StateObject private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard

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
        .task { await environment.bootstrap() }
    }

    enum Tab: Hashable { case dashboard, profiles, logs, settings }
}
