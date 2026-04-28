import Library
import SwiftUI

public struct SettingsView: View {
    @State private var cacheBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var clearError: String?

    // ByteCountFormatter spells "Zero KB" by default; we want "0 KB".
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    public init() {}

    public var body: some View {
        let v = LibmihomoBridge.version

        Form {
            Section("Diagnostics") {
                LabeledContent("App Group") {
                    Text(AppConfiguration.appGroupID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Extension Bundle") {
                    Text(AppConfiguration.extensionBundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("mihomo Core") {
                copyableRow("Version", value: v.mihomo)
                copyableRow("Commit", value: v.mihomoCommit, mono: true)
                copyableRow("Built", value: v.mihomoBuildTime, mono: true)
                copyableRow("Tags", value: v.buildTags.isEmpty ? "—" : v.buildTags, mono: true)
                LabeledContent("Meta") {
                    Image(systemName: v.meta ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(v.meta ? .green : .secondary)
                }
            }

            Section("Runtime") {
                copyableRow("Go", value: v.go, mono: true)
                copyableRow("Platform", value: v.platform, mono: true)
                copyableRow("Wrapper built", value: v.wrapperBuildTime, mono: true)
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
                Text("Removes the rule-provider cache, GeoIP / GeoSite databases, and the downloaded external UI. mihomo re-fetches them on next start.")
            }

            Section("About") {
                LabeledContent("App Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                }
                Link("mihomo on GitHub", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
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

    @ViewBuilder
    private func copyableRow(_ label: String, value: String, mono: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}
