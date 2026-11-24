import SwiftUI
import UIKit

/// UIKit-backed monospaced text editor for YAML input. SwiftUI's
/// `TextEditor` rebuilds its underlying `UITextView` aggressively and
/// loses its scroll offset whenever the parent re-renders — which
/// happens on every keystroke in `ProfileEditorView` because the header
/// shows live char/line counts. Wrapping `UITextView` directly avoids
/// the scroll jump.
struct YAMLCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.text = text
        textView.isEditable = isEditable
        return textView
    }

    func updateUIView(_ textView: UITextView, context _: Context) {
        // Only assign when the external binding genuinely diverges — e.g.,
        // async YAML load on appear. Skipping equal assignments keeps the
        // cursor and scroll offset stable while the user is typing.
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            let length = textView.text.utf16.count
            let safeLocation = min(selection.location, length)
            let safeLength = min(selection.location + selection.length, length) - safeLocation
            textView.selectedRange = NSRange(location: safeLocation, length: safeLength)
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
