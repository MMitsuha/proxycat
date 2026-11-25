import Library
import SwiftUI
import UIKit

struct WebEditorSettingsView: View {
    @Environment(ExtensionEnvironment.self) private var environment
    @Environment(HostSettingsStore.self) private var hostSettings

    @State private var portText = ""
    @State private var portError: String?
    @State private var justCopied = false

    var body: some View {
        Form {
            enableSection
            connectionSection
            portSection
        }
        .proxyCatForm()
        .navigationTitle("Web Editor")
        .accessibilityIdentifier("screen.webEditor")
        .onAppear {
            portText = String(hostSettings.webEditor.port)
        }
        .onChange(of: hostSettings.webEditor.port) { _, newPort in
            portText = String(newPort)
        }
        .alert("Copied", isPresented: $justCopied) {
            Button("OK", role: .cancel) {}
        }
    }

    private var enableSection: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 12) {
                    ProxyCatIconTile(systemImage: "network", tint: .cyan)
                    Text("Enable Web Editor")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open a small editor from another device on the same network. It is only available while ProxyCat is in the foreground and requires the token shown below.")
                Text("Only use the web editor on a trusted local network. It uses unencrypted HTTP; keep the access token private.")
                Text("If the browser cannot connect, allow Local Network for ProxyCat in iOS Settings → Privacy & Security → Local Network, and make sure both devices are on the same Wi-Fi.")
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            statusRow

            if case let .failed(message) = environment.webConfig.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button {
                    environment.webConfig.apply(hostSettings.webEditor)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if let url = environment.webConfig.accessURL,
               let token = environment.webConfig.token {
                LabeledContent("Access URL") {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    Text(token)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    copy(url.absoluteString)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                Button {
                    copy(token)
                } label: {
                    Label("Copy Token", systemImage: "key")
                }
                Link(destination: url) {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
        }
    }

    private var portSection: some View {
        Section {
            LabeledContent("Port") {
                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
            }
            Button {
                applyPort()
            } label: {
                Label("Save", systemImage: "checkmark.circle")
            }
            .disabled(portText == String(hostSettings.webEditor.port))
            if let portError {
                Text(portError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Choose a port from 1024 to 65535. Changing the port while the editor is running restarts it with the same token.")
        }
    }

    private var statusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            statusValue
        }
    }

    @ViewBuilder
    private var statusValue: some View {
        switch environment.webConfig.state {
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting")
            }
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { hostSettings.webEditor.isEnabled },
            set: { isEnabled in
                var settings = hostSettings.webEditor
                settings.isEnabled = isEnabled
                hostSettings.webEditor = settings
                environment.webConfig.apply(settings)
                portError = nil
            }
        )
    }

    private func applyPort() {
        guard let port = Int(portText), WebEditorSettings.portRange.contains(port) else {
            portError = String(localized: "Port must be between 1024 and 65535.", bundle: .main)
            return
        }
        portError = nil
        var settings = hostSettings.webEditor
        settings.port = port
        hostSettings.webEditor = settings
        environment.webConfig.apply(settings)
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        justCopied = true
    }
}
