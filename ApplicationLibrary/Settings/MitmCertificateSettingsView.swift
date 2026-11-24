import Library
import Security
import SwiftUI
import UIKit

struct MitmCertificateSettingsView: View {
    @State private var certificateStatus: MitmCertificateStatus = .missing
    @State private var certificateError: String?
    @State private var certificateShareItem: MitmCertificateShareItem?
    @State private var isPreparingCertificate = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
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
            } footer: {
                Text(certificateStatus.footer)
            }
        }
        .proxyCatForm()
        .navigationTitle("MITM Certificate")
        .task {
            await refreshCertificateStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshCertificateStatus() }
        }
        .sheet(item: $certificateShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .errorAlert($certificateError, title: "Certificate install failed")
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

private struct MitmCertificateShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
