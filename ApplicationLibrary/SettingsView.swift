import Library
import SwiftUI

public struct SettingsView: View {
    @State private var cacheBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var clearError: String?
    @State private var isClearing = false

    @Environment(RuntimeSettings.self) private var settings
    @Environment(HostSettingsStore.self) private var hostSettings

    public init() {}

    public var body: some View {
        @Bindable var settings = settings
        @Bindable var hostSettings = hostSettings
        return Form {
            Section {
                Toggle("Disable Web Controller", isOn: $settings.disableExternalController)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stops mihomo's HTTP controller and bundled Web UI from binding. The host app continues to work via its private connection. Applies immediately while connected.")
            }

            Section {
                LabeledContent("Cache size") {
                    Text(ByteFormatter.fileSize(cacheBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    HStack {
                        Label("Clear cache", systemImage: "trash")
                        if isClearing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(cacheBytes == 0 || isClearing)
            } header: {
                Text("Storage")
            } footer: {
                Text("Removes the rule-provider cache, downloaded GeoIP / GeoSite databases, and the downloaded external UI. mihomo re-fetches them on next start. Bundled assets are preserved.")
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

            Section("About") {
                LabeledContent("App Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                Link("ProxyCat on GitHub", destination: URL(string: "https://github.com/MMitsuha/proxycat")!)
                Link("mihomo on GitHub", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }

            Section {
                NavigationLink {
                    StatisticsView()
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    AutoConnectSettingsView()
                } label: {
                    Label("Auto Connect", systemImage: "wifi.circle")
                }
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .navigationTitle("Settings")
        .task { await refreshCacheSize() }
        .confirmationDialog(
            "Clear cache?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiles are kept. If the tunnel is running, the freed space won't be visible until the next reconnect.")
        }
        .errorAlert($clearError, title: "Clear failed")
    }

    private func refreshCacheSize() async {
        let size = await Task.detached(priority: .userInitiated) {
            FilePath.cacheSize()
        }.value
        cacheBytes = size
    }

    private func clearCache() {
        // Enumeration + unlink can take real time on a large
        // working directory (downloaded UI bundles, fat geo databases).
        // Run it off the main actor so the Settings screen stays
        // responsive; the button shows a spinner via `isClearing` while
        // the work runs.
        isClearing = true
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try FilePath.clearCache()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success:
                await refreshCacheSize()
            case let .failure(error):
                clearError = error.localizedDescription
            }
            isClearing = false
        }
    }
}
