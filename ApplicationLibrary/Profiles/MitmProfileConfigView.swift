import Library
import SwiftUI

struct MitmProfileConfigView: View {
    private struct RuleEditorState: Identifiable {
        enum Mode {
            case add
            case edit(UUID)
        }

        let id = UUID()
        var mode: Mode
        var rule: MitmRewriteRule
    }

    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: Profile

    @State private var isEnabled = false
    @State private var domains: [String] = []
    @State private var ports: [UInt16] = [443]
    @State private var encryptedSNIPolicy: MitmProfileConfig.EncryptedSNIPolicy = .skip
    @State private var rules: [MitmRewriteRule] = []
    @State private var originalConfig: MitmProfileConfig?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var newDomainText = ""
    @State private var showAddDomain = false
    @State private var addDomainError: String?
    @State private var newPortText = ""
    @State private var showAddPort = false
    @State private var addPortError: String?
    @State private var ruleEditor: RuleEditorState?

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                profileSection
                mitmSection
                portsSection
                domainsSection
                rulesSection
                certificateSection
            }
        }
        .navigationTitle("MITM Config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await loadInitial() }
        .alert("Add Domain", isPresented: $showAddDomain) {
            TextField("Domain", text: $newDomainText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { commitNewDomain() }
            Button("Cancel", role: .cancel) { resetDomainInput() }
        } message: {
            if let addDomainError {
                Text(addDomainError)
            } else {
                Text("Use mihomo domain-list syntax, such as +.example.com or domain.com.")
            }
        }
        .alert("Add Port", isPresented: $showAddPort) {
            TextField("Port", text: $newPortText)
                .keyboardType(.numberPad)
            Button("Add") { commitNewPort() }
            Button("Cancel", role: .cancel) { resetPortInput() }
        } message: {
            if let addPortError {
                Text(addPortError)
            } else {
                Text("Enter a TCP port from 1 to 65535.")
            }
        }
        .sheet(item: $ruleEditor) { editor in
            NavigationStack {
                MitmRewriteRuleEditor(rule: editor.rule) { saved in
                    commitRule(saved, mode: editor.mode)
                }
            }
        }
        .errorAlert($errorMessage, title: "MITM config failed")
    }

    private var profileSection: some View {
        Section {
            LabeledContent("Profile") {
                Text(profile.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let remoteURL = profile.remoteURL {
                LabeledContent("Source") {
                    Text(remoteURL.host() ?? remoteURL.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var mitmSection: some View {
        Section {
            Toggle("Enable MITM", isOn: $isEnabled)

            Picker("Encrypted SNI", selection: $encryptedSNIPolicy) {
                ForEach(MitmProfileConfig.EncryptedSNIPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Encrypted SNI controls connections where the TLS ClientHello hides the hostname.")
        }
    }

    private var portsSection: some View {
        Section {
            ForEach(ports, id: \.self) { port in
                Text(String(port))
            }
            .onDelete { offsets in
                ports.remove(atOffsets: offsets)
            }
            Button {
                resetPortInput()
                addPortError = nil
                showAddPort = true
            } label: {
                Label("Add Port", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Ports")
        } footer: {
            Text("MITM only runs for TCP destinations listed here. Add at least one port before enabling MITM.")
        }
    }

    private var domainsSection: some View {
        Section {
            ForEach(domains, id: \.self) { domain in
                Text(domain)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .onDelete { offsets in
                domains.remove(atOffsets: offsets)
            }
            Button {
                resetDomainInput()
                addDomainError = nil
                showAddDomain = true
            } label: {
                Label("Add Domain", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Domain Filter")
        } footer: {
            Text("Leave empty to match every configured port.")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach(rules) { rule in
                Button {
                    ruleEditor = RuleEditorState(mode: .edit(rule.id), rule: rule)
                } label: {
                    MitmRewriteRuleRow(rule: rule)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                rules.remove(atOffsets: offsets)
            }
            Button {
                ruleEditor = RuleEditorState(mode: .add, rule: MitmRewriteRule())
            } label: {
                Label("Add Rule", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Rewrite Rules")
        } footer: {
            Text("Rules are evaluated in order. Save validates the whole profile with mihomo before writing.")
        }
    }

    private var certificateSection: some View {
        Section {
            NavigationLink {
                MitmCertificateSettingsView()
            } label: {
                Label("MITM Certificate", systemImage: "shield.lefthalf.filled")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        FormSaveToolbar(
            isWorking: isSaving,
            canSave: canSave,
            onCancel: { dismiss() },
            onSave: { Task { await save() } }
        )
    }

    private var currentConfig: MitmProfileConfig {
        MitmProfileConfig(
            isEnabled: isEnabled,
            domains: domains,
            ports: ports,
            encryptedSNIPolicy: encryptedSNIPolicy,
            rules: rules
        )
    }

    private var canSave: Bool {
        guard !isLoading, !isSaving, let originalConfig else { return false }
        return currentConfig != originalConfig
    }

    private func apply(_ config: MitmProfileConfig) {
        isEnabled = config.isEnabled
        domains = config.domains
        ports = config.ports
        encryptedSNIPolicy = config.encryptedSNIPolicy
        rules = config.rules
        originalConfig = config
    }

    private func loadInitial() async {
        guard isLoading else { return }
        do {
            let yaml = try await ProfileStore.readYAML(of: profile)
            apply(MitmProfileConfigYAML.config(from: yaml))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let config = currentConfig
            let latestYAML = try await ProfileStore.readYAML(of: profile)
            let updatedYAML = try MitmProfileConfigYAML.replacingConfig(in: latestYAML, with: config)

            try await store.updateContent(of: profile, yaml: updatedYAML)
            originalConfig = currentConfig
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitNewDomain() {
        let trimmed = newDomainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            scheduleAddDomainError(String(localized: "Domain cannot be empty."))
            return
        }
        if domains.contains(trimmed) {
            scheduleAddDomainError(String(localized: "Already in the list."))
            return
        }
        domains.append(trimmed)
        resetDomainInput()
    }

    private func commitNewPort() {
        let trimmed = newPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let parsed = try MitmProfileConfigYAML.parsePortsText(trimmed)
            guard let port = parsed.first, parsed.count == 1 else {
                scheduleAddPortError(String(localized: "Enter one port."))
                return
            }
            if ports.contains(port) {
                scheduleAddPortError(String(localized: "Already in the list."))
                return
            }
            ports.append(port)
            ports.sort()
            resetPortInput()
        } catch {
            scheduleAddPortError(error.localizedDescription)
        }
    }

    private func scheduleAddDomainError(_ message: String) {
        Task { @MainActor in
            addDomainError = message
            showAddDomain = true
        }
    }

    private func scheduleAddPortError(_ message: String) {
        Task { @MainActor in
            addPortError = message
            showAddPort = true
        }
    }

    private func resetDomainInput() {
        newDomainText = ""
    }

    private func resetPortInput() {
        newPortText = ""
    }

    private func commitRule(_ rule: MitmRewriteRule, mode: RuleEditorState.Mode) {
        switch mode {
        case .add:
            rules.append(rule)
        case let .edit(id):
            if let index = rules.firstIndex(where: { $0.id == id }) {
                rules[index] = rule
            }
        }
        ruleEditor = nil
    }
}
