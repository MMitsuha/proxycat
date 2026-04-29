import Library
import SwiftUI

struct AdvancedSettingsView: View {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    var body: some View {
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

            bundledAssetsSection
        }
        .navigationTitle("Advanced")
    }

    @ViewBuilder
    private var bundledAssetsSection: some View {
        let assets = BundledAssets.all
        Section {
            if assets.isEmpty {
                Text("No assets bundled with this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assets) { asset in
                    LabeledContent(asset.displayName) {
                        HStack(spacing: 6) {
                            Text(label(for: asset.kind))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                            Text(Self.byteFormatter.string(fromByteCount: asset.bundledSize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Bundled Assets")
        } footer: {
            if assets.isEmpty {
                Text("Drop GeoIP / GeoSite / MMDB files into BundledAssets/geo/ and an external-ui directory at BundledAssets/ui/, then re-run xcodegen and rebuild to embed them at compile time.")
            } else {
                Text("Embedded in the app at compile time and copied to the working directory on first run. They survive Clear Cache and are not re-downloaded by mihomo.")
            }
        }
    }

    private func label(for kind: BundledAsset.Kind) -> String {
        switch kind {
        case .geo: return "GEO"
        case .externalUI: return "UI"
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
