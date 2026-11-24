import Library
import SwiftUI

extension MitmProfileConfig.EncryptedSNIPolicy {
    var title: LocalizedStringKey {
        switch self {
        case .skip: return "Skip"
        case .mitm: return "MITM"
        case .reject: return "Reject"
        }
    }
}

extension MitmRewriteRule.Action {
    var title: LocalizedStringKey {
        switch self {
        case .reject: return "Reject 404"
        case .reject200: return "Reject 200"
        case .rejectImg: return "Reject Image"
        case .rejectDict: return "Reject Dict"
        case .rejectArray: return "Reject Array"
        case .redirect302: return "302 Redirect"
        case .redirect307: return "307 Redirect"
        case .requestHeader: return "Request Header"
        case .requestBody: return "Request Body"
        case .responseHeader: return "Response Header"
        case .responseBody: return "Response Body"
        }
    }

    var newFieldTitle: LocalizedStringKey {
        switch self {
        case .redirect302, .redirect307:
            return "Redirect URL"
        case .requestHeader, .responseHeader:
            return "New Header"
        case .requestBody, .responseBody:
            return "Replacement"
        case .reject, .reject200, .rejectImg, .rejectDict, .rejectArray:
            return "New"
        }
    }
}

struct MitmRewriteRuleRow: View {
    let rule: MitmRewriteRule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(rule.action.title)
                    .font(.body)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(rule.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}

struct MitmRewriteRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MitmRewriteRule
    @State private var errorMessage: String?

    let onSave: (MitmRewriteRule) -> Void

    init(rule: MitmRewriteRule, onSave: @escaping (MitmRewriteRule) -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                Picker("Action", selection: $rule.action) {
                    ForEach(MitmRewriteRule.Action.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.menu)

                TextField("URL Regex", text: $rule.url, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if rule.action.usesPatternReplacement {
                Section {
                    TextField("Old Pattern", text: $rule.old, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Leave empty to match the full header or body.")
                }
            }

            if rule.action.requiresNewValue {
                Section {
                    TextField(rule.action.newFieldTitle, text: $rule.new, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .proxyCatForm()
        .navigationTitle("Rewrite Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            FormSaveToolbar(
                isWorking: false,
                canSave: true,
                onCancel: { dismiss() },
                onSave: { save() }
            )
        }
        .errorAlert($errorMessage, title: "Rule is incomplete")
    }

    private func save() {
        if rule.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = String(localized: "URL pattern cannot be empty.")
            return
        }
        if rule.action.requiresNewValue,
           rule.new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = String(localized: "Replacement value cannot be empty.")
            return
        }
        onSave(rule)
    }
}
