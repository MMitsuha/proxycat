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
                NavigationLink {
                    AutoConnectSettingsView()
                } label: {
                    Label("Auto Connect", systemImage: "wifi.circle")
                }
                NavigationLink {
                    StatisticsView()
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    ICloudBackupSettingsView()
                } label: {
                    Label("iCloud Backup", systemImage: "icloud")
                }
            }

            Section {
                Toggle("Disable Web Controller", isOn: $settings.disableExternalController)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stops mihomo's HTTP controller and bundled Web UI from binding. The host app continues to work via its private connection. Applies immediately while connected.")
            }

            Section {
                Picker("Retention", selection: $hostSettings.logRetention) {
                    Text("Forever").tag(LogRetention.keepAll)
                    Text("Keep last 10 sessions").tag(LogRetention.last10)
                    Text("Keep last 50 sessions").tag(LogRetention.last50)
                    Text("Keep last 100 sessions").tag(LogRetention.last100)
                }
            } header: {
                Text("Logs")
            } footer: {
                Text("Caps how many per-session log files are kept under Saved Logs. The current session is always preserved. Older files are removed when this setting changes, when the app foregrounds, and when the Saved Logs list is opened.")
            }

            Section {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
                NavigationLink {
                    MitmCertificateSettingsView()
                } label: {
                    Label("MITM Certificate", systemImage: "shield.lefthalf.filled")
                }
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }

            Section("About") {
                LabeledContent("App Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                if let proxyCatURL = SettingsLinks.proxyCat {
                    Link("ProxyCat on GitHub", destination: proxyCatURL)
                }
                if let mihomoURL = SettingsLinks.mihomo {
                    Link("mihomo on GitHub", destination: mihomoURL)
                }
            }
        }
        .navigationTitle("Settings")
    }
}

private enum SettingsLinks {
    static let proxyCat = URL(string: "https://github.com/MMitsuha/proxycat")
    static let mihomo = URL(string: "https://github.com/MMitsuha/mihomo")
}
