import Library
import SwiftUI

public struct SettingsView: View {
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

            Section("About") {
                LabeledContent("App Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                }
                Link("mihomo on GitHub", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }
        }
        .navigationTitle("Settings")
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
