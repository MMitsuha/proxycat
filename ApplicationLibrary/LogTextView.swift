import SwiftUI
import UIKit

/// UITextView-backed text display for the saved-log detail screen.
/// SwiftUI's `Text` measures the entire string in one pass, which
/// freezes and crashes on MB-sized logs. UITextView uses TextKit's
/// incremental layout and handles megabytes of text natively, with
/// system-standard scrolling and selection. Keep this view dumb —
/// it just renders the string the parent already loaded.
struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context _: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.systemFontSize - 4,
            weight: .regular
        )
        return view
    }

    func updateUIView(_ view: UITextView, context _: Context) {
        // Skip the assignment when content hasn't changed: re-setting
        // .text on a multi-MB string forces TextKit to re-lay-out the
        // whole document and momentarily blocks the main thread, which
        // would happen on every parent state change otherwise.
        if view.text != text {
            view.text = text
        }
    }
}
