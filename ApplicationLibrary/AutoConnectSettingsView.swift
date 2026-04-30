import Library
import SwiftUI

/// Settings sub view for the Auto Connect feature. The master toggle
/// drives `AutoConnectConfig.enabled`; the rest of the sections (SSID
/// rules, cellular, default) only render when enabled is true so the
/// user has a clear visual signal that nothing is in effect.
public struct AutoConnectSettingsView: View {
    @ObservedObject private var store = HostSettingsStore.shared
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var environment: ExtensionEnvironment

    @State private var isAddingSSID = false
    @State private var newSSIDText = ""
    @State private var ssidError: String?

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
        .alert("Add SSID", isPresented: $isAddingSSID) {
            TextField("Network name", text: $newSSIDText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { commitNewSSID() }
            Button("Cancel", role: .cancel) { resetSSIDInput() }
        } message: {
            if let ssidError {
                Text(ssidError)
            } else {
                Text("Enter the exact Wi-Fi name. iOS matches case-sensitively.")
            }
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { environment.autoConnectError != nil },
                set: { if !$0 { environment.autoConnectError = nil } }
            )
        ) {
            Button("OK") { environment.autoConnectError = nil }
        } message: {
            Text(environment.autoConnectError ?? "")
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
                HStack {
                    Text(rule.ssid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    actionPicker(selection: $rule.action)
                }
            }
            .onDelete { offsets in
                store.autoConnect.ssidRules.remove(atOffsets: offsets)
            }
            Button {
                resetSSIDInput()
                isAddingSSID = true
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
            HStack {
                Text("Cellular")
                Spacer()
                actionPicker(selection: $store.autoConnect.cellular)
            }
        }
    }

    private var fallbackSection: some View {
        Section {
            HStack {
                Text("Default")
                Spacer()
                actionPicker(selection: $store.autoConnect.fallback)
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

    private func actionPicker(selection: Binding<AutoConnectAction>) -> some View {
        Picker("Action", selection: selection) {
            Text("Connect").tag(AutoConnectAction.connect)
            Text("Disconnect").tag(AutoConnectAction.disconnect)
            Text("Ignore").tag(AutoConnectAction.ignore)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func commitNewSSID() {
        let trimmed = newSSIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ssidError = String(localized: "Network name cannot be empty.")
            isAddingSSID = true
            return
        }
        if store.autoConnect.ssidRules.contains(where: { $0.ssid == trimmed }) {
            ssidError = String(localized: "Already in the list.")
            isAddingSSID = true
            return
        }
        store.autoConnect.ssidRules.append(
            SSIDRule(ssid: trimmed, action: .connect)
        )
        resetSSIDInput()
    }

    private func resetSSIDInput() {
        newSSIDText = ""
        ssidError = nil
    }
}
