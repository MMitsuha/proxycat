import SwiftUI

/// `.errorAlert($message)` — shows an alert whenever `message` is non-nil
/// and clears it back to nil when dismissed. Replaces the
/// `alert(isPresented: .constant(message != nil))` pattern that several
/// views were duplicating verbatim.
public extension View {
    func errorAlert(
        _ message: Binding<String?>,
        title: LocalizedStringKey = "Error"
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
