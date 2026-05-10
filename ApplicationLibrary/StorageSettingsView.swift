import Library
import SwiftUI

struct StorageSettingsView: View {
    @State private var cacheBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var clearError: String?
    @State private var isClearing = false

    var body: some View {
        Form {
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
            } footer: {
                Text("Removes the rule-provider cache, downloaded GeoIP / GeoSite databases, and the downloaded external UI. mihomo re-fetches them on next start. Bundled assets are preserved.")
            }
        }
        .navigationTitle("Storage")
        .task {
            await refreshCacheSize()
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
        // Run it off the main actor so this screen stays responsive; the
        // button shows a spinner via `isClearing` while the work runs.
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
}
