import Library
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment

    @State private var defaultLogLevel: LogLevel = .info
    @State private var availableMemory: Int = 0
    @State private var memoryTimer: Timer?

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
                LabeledContent("Available memory") {
                    Text(availableMemory > 0 ? ByteFormatter.string(Int64(availableMemory)) : "—")
                        .font(.system(.body, design: .monospaced))
                }
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
        .onAppear { startMemoryPoll() }
        .onDisappear { stopMemoryPoll() }
    }

    private func startMemoryPoll() {
        availableMemory = MemoryMonitor.availableBytes()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            availableMemory = MemoryMonitor.availableBytes()
        }
    }

    private func stopMemoryPoll() {
        memoryTimer?.invalidate()
        memoryTimer = nil
    }
}
