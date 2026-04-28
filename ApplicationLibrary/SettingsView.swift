import Library
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment

    @State private var defaultLogLevel: LogLevel = .info

    public init() {}

    public var body: some View {
        Form {
            Section("Logging") {
                Picker("Default Level", selection: $defaultLogLevel) {
                    ForEach(LogLevel.allCases) { lvl in
                        Text(lvl.displayName).tag(lvl)
                    }
                }
                .onChange(of: defaultLogLevel) { newValue in
                    environment.commandClient.defaultLogLevel = newValue
                }
            }
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
            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                }
                Link("mihomo on GitHub", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }
        }
        .navigationTitle("Settings")
    }
}
