import Library
import SwiftUI

public struct SettingsView: View {
    @State private var cacheBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var clearError: String?

    @ObservedObject private var settings = RuntimeSettings.shared

    // ByteCountFormatter spells "Zero KB" by default; we want "0 KB".
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Disable Web Controller", isOn: $settings.disableExternalController)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stops mihomo's HTTP controller and bundled Web UI from binding. The host app continues to work via its private connection. Applies immediately while connected.")
            }

            Section {
                LabeledContent("Cache size") {
                    Text(Self.byteFormatter.string(fromByteCount: cacheBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear cache", systemImage: "trash")
                }
                .disabled(cacheBytes == 0)
            } header: {
                Text("Storage")
            } footer: {
                Text("Removes the rule-provider cache, downloaded GeoIP / GeoSite databases, and the downloaded external UI. mihomo re-fetches them on next start. Bundled assets are preserved.")
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
        .alert("Clear failed", isPresented: .constant(clearError != nil)) {
            Button("OK") { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    private func refreshCacheSize() async {
        let size = await Task.detached(priority: .userInitiated) {
            FilePath.cacheSize()
        }.value
        cacheBytes = size
    }

    private func clearCache() {
        do {
            try FilePath.clearCache()
            Task { await refreshCacheSize() }
        } catch {
            clearError = error.localizedDescription
        }
    }
}
