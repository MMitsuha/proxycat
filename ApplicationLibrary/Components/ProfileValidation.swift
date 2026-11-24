import SwiftUI

/// Result of running mihomo's YAML parser on a profile candidate.
/// `pristine` is the UI's "not yet validated" state, not a parser outcome.
public enum ProfileValidation: Equatable {
    case pristine
    case ok
    case failed(String)
}

/// Form footer that surfaces a `ProfileValidation`.
public struct ProfileValidationFooter: View {
    public let validation: ProfileValidation
    public let pristineHint: LocalizedStringKey

    public init(validation: ProfileValidation, pristineHint: LocalizedStringKey) {
        self.validation = validation
        self.pristineHint = pristineHint
    }

    public var body: some View {
        switch validation {
        case .pristine:
            Text(pristineHint)
        case .ok:
            Label("Configuration looks valid.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label {
                Text(message)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }
    }
}
