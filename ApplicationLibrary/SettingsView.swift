import Library
import Security
import SwiftUI
import UIKit

public struct SettingsView: View {
    @State private var cacheBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var clearError: String?
    @State private var isClearing = false
    @State private var certificateStatus: MitmCertificateStatus = .missing
    @State private var certificateError: String?
    @State private var certificateShareItem: MitmCertificateShareItem?
    @State private var isPreparingCertificate = false

    @Environment(\.scenePhase) private var scenePhase
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
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        Image(systemName: certificateStatus.systemImage)
                        Text(certificateStatus.title)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(certificateStatus.tint)
                }

                Button {
                    installCertificate()
                } label: {
                    HStack {
                        Label("Install Certificate", systemImage: "square.and.arrow.down")
                        if isPreparingCertificate {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isPreparingCertificate)

                Button {
                    Task { await refreshCertificateStatus() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("MITM Certificate")
            } footer: {
                Text(certificateStatus.footer)
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
        .task {
            await refreshCacheSize()
            await refreshCertificateStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshCertificateStatus() }
        }
        .sheet(item: $certificateShareItem) { item in
            ShareSheet(items: [item.url])
        }
        // .alert (modal) instead of .confirmationDialog: on iOS 26 the
        // dialog renders as a popover with a full-screen dismiss region,
        // so an impatient second tap on the trigger button lands on the
        // dismiss region and cancels the popover the first tap just
        // opened — the user reads it as "needed two taps".
        .alert(
            "Clear cache?",
            isPresented: $showClearConfirm
        ) {
            Button("Clear", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiles are kept. If the tunnel is running, the freed space won't be visible until the next reconnect.")
        }
        .errorAlert($clearError, title: "Clear failed")
        .errorAlert($certificateError, title: "Certificate install failed")
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

    private func refreshCertificateStatus() async {
        let result = await loadCertificateStatus(createIfNeeded: false)
        if case let .success(status) = result {
            certificateStatus = status
        }
    }

    private func installCertificate() {
        isPreparingCertificate = true
        Task {
            let result = await loadCertificateStatus(createIfNeeded: true)
            isPreparingCertificate = false
            switch result {
            case let .success(status):
                certificateStatus = status
                guard let url = status.url else { return }
                openCertificate(url)
            case let .failure(error):
                certificateError = error.localizedDescription
            }
        }
    }

    private func loadCertificateStatus(createIfNeeded: Bool) async -> Result<MitmCertificateStatus, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try MitmCertificateInspector.status(createIfNeeded: createIfNeeded))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func openCertificate(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                certificateShareItem = MitmCertificateShareItem(url: url)
            }
        }
    }
}

private enum SettingsLinks {
    static let proxyCat = URL(string: "https://github.com/MMitsuha/proxycat")
    static let mihomo = URL(string: "https://github.com/MMitsuha/mihomo")
}

private struct MitmCertificateShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MitmCertificateStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case missing
        case notTrusted
        case trusted
        case invalid
    }

    var kind: Kind
    var url: URL?

    static let missing = MitmCertificateStatus(kind: .missing, url: nil)

    var title: LocalizedStringKey {
        switch kind {
        case .missing: return "Not Created"
        case .notTrusted: return "Not Trusted"
        case .trusted: return "Trusted"
        case .invalid: return "Invalid"
        }
    }

    var systemImage: String {
        switch kind {
        case .missing: "circle.dashed"
        case .notTrusted: "exclamationmark.shield"
        case .trusted: "checkmark.shield.fill"
        case .invalid: "xmark.shield"
        }
    }

    var tint: Color {
        switch kind {
        case .missing: .secondary
        case .notTrusted: .orange
        case .trusted: .green
        case .invalid: .red
        }
    }

    var footer: LocalizedStringKey {
        switch kind {
        case .missing:
            return "Create and install the local root CA before using MITM HTTPS rewriting."
        case .notTrusted:
            return "After opening the certificate, install the downloaded profile in iOS Settings > General > VPN & Device Management, then enable full trust in Settings > General > About > Certificate Trust Settings."
        case .trusted:
            return "The local MITM root CA is trusted by iOS. HTTPS rewriting can work for profiles that enable MITM."
        case .invalid:
            return "The certificate file is invalid. Install again to create a fresh certificate."
        }
    }
}

private enum MitmCertificateInspector {
    static func status(createIfNeeded: Bool) throws -> MitmCertificateStatus {
        let url = try certificateURL(createIfNeeded: createIfNeeded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard FileManager.default.fileExists(atPath: FilePath.mitmPrivateKeyFile.path) else {
            return MitmCertificateStatus(kind: .invalid, url: url)
        }

        let trusted: Bool
        do {
            trusted = try isTrustedForHTTPS()
        } catch {
            return MitmCertificateStatus(kind: .invalid, url: url)
        }
        return MitmCertificateStatus(
            kind: trusted ? .trusted : .notTrusted,
            url: url
        )
    }

    private static func certificateURL(createIfNeeded: Bool) throws -> URL {
        if createIfNeeded {
            LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)
            return try LibmihomoBridge.ensureMitmCertificate()
        }
        return FilePath.mitmCertificateFile
    }

    private static func certificates(fromPEM data: Data) -> [SecCertificate] {
        guard let pem = String(data: data, encoding: .ascii) else {
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return [] }
            return [certificate]
        }

        var certificates: [SecCertificate] = []
        var searchStart = pem.startIndex
        while let begin = pem.range(of: "-----BEGIN CERTIFICATE-----", range: searchStart..<pem.endIndex),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex) {
            let base64 = pem[begin.upperBound..<end.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let der = Data(base64Encoded: base64),
               let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                certificates.append(certificate)
            }
            searchStart = end.upperBound
        }
        return certificates
    }

    private static func isTrustedForHTTPS() throws -> Bool {
        let probeHost = "mitm.mihomo"
        let chain = certificates(fromPEM: try LibmihomoBridge.mitmTrustProbePEM(host: probeHost))
        guard !chain.isEmpty else { return false }

        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            chain as CFArray,
            SecPolicyCreateSSL(true, probeHost as CFString),
            &trust
        )
        guard status == errSecSuccess, let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
