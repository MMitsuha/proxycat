import Library
import SafariServices
import SwiftUI
import UIKit

struct WebEditorSettingsView: View {
    @Environment(ExtensionEnvironment.self) private var environment
    @Environment(HostSettingsStore.self) private var hostSettings

    @State private var portText = ""
    @State private var portError: String?
    @State private var justCopied = false
    @State private var showingSafari = false
    @FocusState private var portFieldFocused: Bool

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
            // The host may have moved to a different Wi-Fi network (or
            // finished connecting) since the listener started.
            environment.webConfig.refreshURLs()
        }
        .onChange(of: hostSettings.webEditor.port) { _, newPort in
            let updated = String(newPort)
            if portText != updated {
                portText = updated
            }
        }
        .onChange(of: portFieldFocused) { _, focused in
            if !focused {
                commitPort(restoreOnFailure: true)
            }
        }
        .onDisappear {
            // Don't lose a valid port typed just before navigating away;
            // the debounce may not have fired yet.
            commitPort(restoreOnFailure: false)
        }
        .sheet(isPresented: $showingSafari) {
            if let url = environment.webConfig.localURL ?? environment.webConfig.accessURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
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
            .accessibilityIdentifier("webEditor.enable")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open a small editor from another device on the same network. It is only available while ProxyCat is in the foreground and requires the access token.")
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

            if let baseURL = environment.webConfig.baseURL,
               let accessURL = environment.webConfig.accessURL,
               let token = environment.webConfig.token {
                VStack(alignment: .leading, spacing: 10) {
                    ProxyCatMetricHeader(
                        title: "Access URL",
                        systemImage: "network",
                        tint: .cyan
                    )
                    Text(baseURL.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("webEditor.accessURL")
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            ProxyCatUI.pageBackground,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )

                    HStack(spacing: 8) {
                        Button {
                            copy(accessURL.absoluteString)
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("webEditor.copyLink")

                        Button {
                            copy(token)
                        } label: {
                            Label("Copy Token", systemImage: "key")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("webEditor.copyToken")

                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)

                    Text("The token is hidden. Copy Link opens the editor with the token included, or copy the token and paste it into the page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if environment.webConfig.isLoopbackOnly {
                        Text("No LAN address was found. This URL only works on this device; connect to Wi-Fi and reopen this screen to share it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)

                // Opening the system Safari app backgrounds ProxyCat, which
                // stops the listener before the page can load. Present the
                // in-app browser instead; the scene stays active and
                // loopback works on this device.
                Button {
                    showingSafari = true
                } label: {
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
                    .focused($portFieldFocused)
                    .accessibilityIdentifier("webEditor.port")
            }
            if let portError {
                Text(portError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Choose a port from 1024 to 65535. Changes apply automatically; changing the port while the editor is running restarts it with the same token.")
        }
        .task(id: portText) {
            // Debounce commits so a transiently parseable prefix of a
            // larger value ("9999" on the way to "99999") never gets
            // persisted and restarts the listener on the wrong port.
            guard !portText.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            commitPort(restoreOnFailure: false)
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

    /// Persists a valid port and never commits an invalid or empty value.
    /// On focus loss the field is restored to the persisted port so the
    /// text on screen can't disagree with the running listener.
    private func commitPort(restoreOnFailure: Bool) {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            portError = nil
            if restoreOnFailure {
                portText = String(hostSettings.webEditor.port)
            }
            return
        }
        guard let port = WebEditorSettings.parsePort(trimmed) else {
            portError = String(localized: "Port must be between 1024 and 65535.", bundle: .main)
            if restoreOnFailure {
                portText = String(hostSettings.webEditor.port)
            }
            return
        }
        portError = nil
        guard port != hostSettings.webEditor.port else { return }
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

/// In-app Safari keeps ProxyCat's scene active, unlike opening the Safari
/// app. Loopback (`127.0.0.1`) URLs need no Local Network permission.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
