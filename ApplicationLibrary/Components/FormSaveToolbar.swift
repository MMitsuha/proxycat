import SwiftUI

/// Standard Cancel / Save trailing toolbar shared by the sheet-based
/// editors. Keeps the "spinner replaces the Save button while working"
/// and "Cancel is disabled during a save" rules in one place.
struct FormSaveToolbar: ToolbarContent {
    var isWorking: Bool
    var canSave: Bool
    var saveSystemImage: String = "checkmark.circle"
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel", action: onCancel)
                .disabled(isWorking)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isWorking {
                ProgressView()
            } else {
                Button(action: onSave) {
                    Label("Save", systemImage: saveSystemImage)
                }
                .disabled(!canSave)
            }
        }
    }
}
