import Library
import SwiftUI

public struct SettingsView: View {
    @Environment(RuntimeSettings.self) private var settings
    @Environment(HostSettingsStore.self) private var hostSettings

    public init() {}

    public var body: some View {
        @Bindable var settings = settings
        @Bindable var hostSettings = hostSettings
        return Form {
            Section {
                ProxyCatNavigationRow(
                    title: "Auto Connect",
                    systemImage: "wifi.circle",
                    tint: .blue,
                    accessibilityID: "settings.autoConnect"
                ) {
                    AutoConnectSettingsView()
                }
                ProxyCatNavigationRow(
                    title: "Statistics",
                    systemImage: "chart.bar.xaxis",
                    tint: .blue,
                    accessibilityID: "settings.statistics"
                ) {
                    StatisticsView()
                }
                ProxyCatNavigationRow(
                    title: "iCloud Backup",
                    systemImage: "icloud",
                    tint: .blue,
                    accessibilityID: "settings.iCloud"
                ) {
                    ICloudBackupSettingsView()
                }
                ProxyCatNavigationRow(
                    title: "Web Editor",
                    systemImage: "network",
                    tint: .cyan,
                    accessibilityID: "settings.webEditor"
                ) {
                    WebEditorSettingsView()
                }
            }

            Section {
                Toggle(isOn: $settings.disableExternalController) {
                    settingsRowLabel(
                        title: "Disable Web Controller",
                        systemImage: "hand.raised.fill",
                        tint: .orange
                    )
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stops mihomo's HTTP controller and bundled Web UI from binding. The host app continues to work via its private connection. Applies immediately while connected.")
            }

            Section {
                Picker(selection: $hostSettings.logRetention) {
                    Text("Forever").tag(LogRetention.keepAll)
                    Text("Keep last 10 sessions").tag(LogRetention.last10)
                    Text("Keep last 50 sessions").tag(LogRetention.last50)
                    Text("Keep last 100 sessions").tag(LogRetention.last100)
                } label: {
                    settingsRowLabel(
                        title: "Retention",
                        systemImage: "archivebox.fill",
                        tint: .teal
                    )
                }
            } header: {
                Text("Logs")
            } footer: {
                Text("Caps how many tunnel sessions are kept under Saved Logs. The current session is always preserved. Older files are removed when this setting changes, when the app foregrounds, and when the Saved Logs list is opened.")
            }

            Section {
                ProxyCatNavigationRow(
                    title: "Storage",
                    systemImage: "internaldrive",
                    tint: .indigo,
                    accessibilityID: "settings.storage"
                ) {
                    StorageSettingsView()
                }
                ProxyCatNavigationRow(
                    title: "MITM Certificate",
                    systemImage: "shield.lefthalf.filled",
                    tint: .green,
                    accessibilityID: "settings.mitmCertificate"
                ) {
                    MitmCertificateSettingsView()
                }
                ProxyCatNavigationRow(
                    title: "Advanced",
                    systemImage: "wrench.and.screwdriver",
                    tint: .gray,
                    accessibilityID: "settings.advanced"
                ) {
                    AdvancedSettingsView()
                }
            }

            Section("About") {
                LabeledContent("App Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                if let proxyCatURL = SettingsLinks.proxyCat {
                    Link(destination: proxyCatURL) {
                        Label("ProxyCat on GitHub", systemImage: "link")
                    }
                }
                if let mihomoURL = SettingsLinks.mihomo {
                    Link(destination: mihomoURL) {
                        Label("mihomo on GitHub", systemImage: "link")
                    }
                }
            }
        }
        .proxyCatForm()
        .navigationTitle("Settings")
        .accessibilityIdentifier("screen.settings.root")
    }

    private func settingsRowLabel(
        title: LocalizedStringKey,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            ProxyCatIconTile(systemImage: systemImage, tint: tint)
            Text(title)
        }
    }
}

private enum SettingsLinks {
    static let proxyCat = URL(string: "https://github.com/MMitsuha/proxycat")
    static let mihomo = URL(string: "https://github.com/MMitsuha/mihomo")
}
