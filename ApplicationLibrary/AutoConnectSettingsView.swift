import Library
import SwiftUI

/// Settings sub view for the Auto Connect feature. The master toggle
/// drives `AutoConnectConfig.enabled`; the rest of the sections (SSID
/// rules, cellular, default) only render when enabled is true so the
/// user has a clear visual signal that nothing is in effect.
public struct AutoConnectSettingsView: View {
    @EnvironmentObject private var store: HostSettingsStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var environment: ExtensionEnvironment

    @State private var newSSIDText = ""
    @State private var showAddSSID = false
    @State private var addSSIDError: String?
    @State private var saveErrorMessage: String?

    public init() {}

    public var body: some View {
        Form {
            masterSection
            if store.autoConnect.enabled {
                ssidSection
                cellularSection
                fallbackSection
            }
            footerSection
        }
        .navigationTitle("Auto Connect")
        .alert("Add SSID", isPresented: $showAddSSID) {
            TextField("Network name", text: $newSSIDText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { commitNewSSID() }
            Button("Cancel", role: .cancel) { resetSSIDInput() }
        } message: {
            if let addSSIDError {
                Text(addSSIDError)
            } else {
                Text("Enter the exact Wi-Fi name. iOS matches case-sensitively.")
            }
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isShowing in
                    if !isShowing {
                        saveErrorMessage = nil
                        // Clear the upstream error too so the alert
                        // doesn't immediately re-fire on the next
                        // observation.
                        environment.autoConnectError = nil
                    }
                }
            ),
            presenting: saveErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: environment.autoConnectError) { _, newValue in
            // Defer the save-error alert if the Add-SSID alert is still
            // up so the user's in-progress input is not stomped.
            guard let message = newValue, !showAddSSID else { return }
            saveErrorMessage = message
        }
    }

    // MARK: - Sections

    private var masterSection: some View {
        Section {
            Toggle("Auto Connect", isOn: $store.autoConnect.enabled)
                .disabled(profileStore.active == nil)
        } footer: {
            if profileStore.active == nil {
                Text("Pick a profile first.")
            } else {
                Text("When on, ProxyCat connects or disconnects automatically based on the rules below. When off, use the Dashboard to control the tunnel manually.")
            }
        }
    }

    private var ssidSection: some View {
        Section {
            ForEach($store.autoConnect.ssidRules) { $rule in
                actionPicker(selection: $rule.action) {
                    Text(rule.ssid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .onDelete { offsets in
                store.autoConnect.ssidRules.remove(atOffsets: offsets)
            }
            Button {
                resetSSIDInput()
                addSSIDError = nil
                showAddSSID = true
            } label: {
                Label("Add SSID", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Wi-Fi SSIDs")
        } footer: {
            Text("iOS evaluates SSIDs case-sensitively. The first matching rule wins; networks not listed fall through to the Default action below.")
        }
    }

    private var cellularSection: some View {
        Section {
            actionPicker(selection: $store.autoConnect.cellular) {
                Text("Cellular")
            }
        }
    }

    private var fallbackSection: some View {
        Section {
            actionPicker(selection: $store.autoConnect.fallback) {
                Text("Default")
            }
        } footer: {
            Text("Used for any network not matched above.")
        }
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("iOS only auto-connects after you have tapped Connect on the Dashboard at least once on this device.")
        }
    }

    // MARK: - Helpers

    /// A Form-native label + menu Picker. Uses Picker's own label
    /// parameter rather than a manual HStack so each row matches the
    /// system's standard Form row height (the manual layout was
    /// noticeably taller).
    @ViewBuilder
    private func actionPicker<Label: View>(
        selection: Binding<AutoConnectAction>,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Picker(selection: selection) {
            Text("Connect").tag(AutoConnectAction.connect)
            Text("Disconnect").tag(AutoConnectAction.disconnect)
            Text("Ignore").tag(AutoConnectAction.ignore)
        } label: {
            label()
        }
        .pickerStyle(.menu)
    }

    private func commitNewSSID() {
        let trimmed = newSSIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            scheduleAddSSIDError(String(localized: "Network name cannot be empty."))
            return
        }
        if store.autoConnect.ssidRules.contains(where: { $0.ssid == trimmed }) {
            scheduleAddSSIDError(String(localized: "Already in the list."))
            return
        }
        store.autoConnect.ssidRules.append(
            SSIDRule(ssid: trimmed, action: .connect)
        )
        resetSSIDInput()
    }

    /// Re-presents the Add-SSID alert on the next runloop turn. Direct
    /// assignment from a Button action is racy: SwiftUI dismisses the
    /// alert after the action runs and calls the binding's setter,
    /// which would clear our mutation. Deferring lets the dismissal
    /// settle first.
    private func scheduleAddSSIDError(_ message: String) {
        Task { @MainActor in
            addSSIDError = message
            showAddSSID = true
        }
    }

    private func resetSSIDInput() {
        newSSIDText = ""
    }
}
