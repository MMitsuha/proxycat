import Library
import SwiftUI

struct ICloudBackupSettingsView: View {
    @State private var showRestoreConfirm = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ICloudBackupStore.self) private var iCloudBackupStore

    var body: some View {
        @Bindable var iCloudBackup = iCloudBackupStore
        return Form {
            Section {
                Toggle("iCloud Sync", isOn: $iCloudBackup.isEnabled)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if iCloudBackup.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: iCloudStatusImage(iCloudBackup.phase))
                        }
                        Text(iCloudStatusTitle(iCloudBackup.phase))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(iCloudStatusTint(iCloudBackup.phase))
                }

                if let lastBackup = iCloudBackup.lastBackup {
                    LabeledContent("Last Backup") {
                        Text(lastBackup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Profiles") {
                        Text(lastBackup.profileCount.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastSyncedAt = iCloudBackup.lastSyncedAt {
                    LabeledContent("Last Sync") {
                        Text(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastError = iCloudBackup.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await iCloudBackupStore.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(!iCloudBackup.isEnabled || iCloudBackup.isSyncing)

                Button {
                    Task { await iCloudBackupStore.backUpNow() }
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!iCloudBackup.isEnabled || iCloudBackup.isSyncing)

                Button(role: .destructive) {
                    showRestoreConfirm = true
                } label: {
                    Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!iCloudBackup.isEnabled || !iCloudBackup.hasCloudBackup || iCloudBackup.isSyncing)
            } footer: {
                Text("Backs up profiles, the active profile, runtime preferences, Auto Connect, and log-retention settings to iCloud Drive. Logs, cache files, usage history, and MITM keys are not included.")
            }
        }
        .navigationTitle("iCloud Backup")
        .task {
            await iCloudBackupStore.refreshStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await iCloudBackupStore.refreshStatus() }
        }
        .alert(
            "Restore from iCloud?",
            isPresented: $showRestoreConfirm
        ) {
            Button("Restore", role: .destructive) {
                Task { await iCloudBackupStore.restoreNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces local profiles and settings with the latest iCloud backup.")
        }
    }

    private func iCloudStatusTitle(_ phase: ICloudBackupPhase) -> LocalizedStringKey {
        switch phase {
        case .disabled: return "Off"
        case .unavailable: return "Unavailable"
        case .ready: return "Ready"
        case .syncing: return "Syncing"
        case .conflict: return "Conflict"
        case .error: return "Error"
        }
    }

    private func iCloudStatusImage(_ phase: ICloudBackupPhase) -> String {
        switch phase {
        case .disabled: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .ready: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .conflict: "exclamationmark.triangle"
        case .error: "xmark.icloud"
        }
    }

    private func iCloudStatusTint(_ phase: ICloudBackupPhase) -> Color {
        switch phase {
        case .disabled: .secondary
        case .unavailable: .orange
        case .ready: .green
        case .syncing: .secondary
        case .conflict: .orange
        case .error: .red
        }
    }
}
