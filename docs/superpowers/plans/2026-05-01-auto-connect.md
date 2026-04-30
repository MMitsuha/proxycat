# Auto Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings sub view that auto-connects or disconnects ProxyCat based on the connected network — a list of specific Wi-Fi SSIDs, an action for cellular, and a fallback default action — gated by a master switch.

**Architecture:** Three new Swift files and five edits. A new umbrella `HostSettings` JSON file (`host_settings.json`) holds all host-only configuration so future host-only features get a field instead of a new file. `HostSettingsStore` mirrors the existing `RuntimeSettings` shape (load on init, atomic writes, `NotificationCenter` broadcast on change). `ExtensionProfile.applyAutoConnect(_:)` translates the config into `NEOnDemandRule[]` and saves to `NETunnelProviderManager.preferences`. `ExtensionEnvironment` applies the rules on bootstrap and on every store change. The sub view is a single SwiftUI `Form` reachable from the existing Settings list.

**Tech Stack:** Swift 5.10, SwiftUI, iOS 17+, `NetworkExtension` framework (`NEOnDemandRule*`). No new entitlements, no `project.yml` edits — `Library` and `ApplicationLibrary` are folder references in XcodeGen, so new files inside them are picked up automatically.

**Spec:** `docs/superpowers/specs/2026-05-01-auto-connect-design.md`

**Testing note (adaptation):** This codebase has no XCTest target (only the Go upstream `mihomo/test/` exists). Strict TDD does not fit. Verification in this plan is:

1. **Compilation** after each code-generating task — `make sim` must succeed.
2. **Manual on-device smoke test** in Task 9, exercising every behavior listed in the spec's test plan. (Simulator does not exercise on-demand rules — they require a real device.)

The model types in Task 1 are pure structs and would unit-test cleanly if a test target is added later.

---

## File Structure

| File | Status | Purpose |
|---|---|---|
| `Library/AutoConnect.swift` | CREATE | Model types: `AutoConnectAction`, `SSIDRule`, `AutoConnectConfig`, umbrella `HostSettings`. Pure value types, no behavior. |
| `Library/HostSettingsStore.swift` | CREATE | `@MainActor` store mirroring `RuntimeSettings`. Loads `host_settings.json`, publishes `autoConnect`, persists atomically, posts notification. |
| `Library/FilePath.swift` | MODIFY | Add `hostSettingsFilePath` next to `settingsFilePath`. |
| `Library/AppConfiguration.swift` | MODIFY | Add `hostSettingsFileName` constant and `hostSettingsDidChange` notification name. |
| `Library/ExtensionProfile.swift` | MODIFY | Add `applyAutoConnect(_:)` and the static rule-builder helpers. |
| `Library/ExtensionEnvironment.swift` | MODIFY | Observe `hostSettingsDidChange`; apply on bootstrap and on each change. Surface errors via `autoConnectError`. |
| `ApplicationLibrary/AutoConnectSettingsView.swift` | CREATE | The sub view: master toggle, SSID rule list with inline pickers, cellular row, default row, footer notes. |
| `ApplicationLibrary/SettingsView.swift` | MODIFY | Add a `NavigationLink` to `AutoConnectSettingsView` above the existing "Advanced" entry. |
| `Localizable.xcstrings` | MODIFY (auto) | Xcode auto-extracts new SwiftUI strings on next build. Sort after extraction per project convention. |

---

## Task 1: Add the data model

**Files:**
- Create: `Library/AutoConnect.swift`

- [ ] **Step 1: Create the new file with the model types**

```swift
import Foundation

/// What to do when an on-demand rule matches.
public enum AutoConnectAction: Int, Codable, CaseIterable, Sendable {
    case ignore = 0
    case connect = 1
    case disconnect = 2
}

/// A single Wi-Fi SSID rule. The action applies when the device joins
/// the named SSID; matching is case-sensitive (iOS does not normalize).
public struct SSIDRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ssid: String
    public var action: AutoConnectAction

    public init(id: UUID = UUID(), ssid: String, action: AutoConnectAction) {
        self.id = id
        self.ssid = ssid
        self.action = action
    }
}

/// User-facing configuration for the Auto Connect feature.
///
/// Translates to a flat `NEOnDemandRule[]` evaluated top-to-bottom by
/// iOS. Order: each SSID rule (Wi-Fi only), then a cellular rule, then
/// a final fallback rule with `interfaceTypeMatch = .any`. First match
/// wins, so SSID rules always override the fallback.
public struct AutoConnectConfig: Codable, Equatable, Sendable {
    /// Master switch. When false the feature is fully off and
    /// `NETunnelProviderManager.isOnDemandEnabled` is set to false.
    public var enabled: Bool
    public var ssidRules: [SSIDRule]
    public var cellular: AutoConnectAction
    /// Action used when no SSID rule and the cellular rule do not match —
    /// covers Wi-Fi networks the user has not named, plus interface
    /// types that aren't Wi-Fi or cellular.
    public var fallback: AutoConnectAction

    public init(
        enabled: Bool,
        ssidRules: [SSIDRule],
        cellular: AutoConnectAction,
        fallback: AutoConnectAction
    ) {
        self.enabled = enabled
        self.ssidRules = ssidRules
        self.cellular = cellular
        self.fallback = fallback
    }

    public static let defaults = AutoConnectConfig(
        enabled: false,
        ssidRules: [],
        cellular: .ignore,
        fallback: .ignore
    )
}

/// Umbrella container for everything persisted in `host_settings.json`.
/// New host-only features become new fields on this struct, not new
/// files. The Go core never reads this file — it's host (iOS) only.
public struct HostSettings: Codable, Equatable, Sendable {
    public var autoConnect: AutoConnectConfig

    public init(autoConnect: AutoConnectConfig) {
        self.autoConnect = autoConnect
    }

    public static let defaults = HostSettings(autoConnect: .defaults)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds. The file has no consumers yet, so this is a syntax-only check.

- [ ] **Step 3: Commit**

```bash
git add Library/AutoConnect.swift
git commit -m "Add Auto Connect data model

AutoConnectAction, SSIDRule, AutoConnectConfig, and the umbrella
HostSettings container that backs host_settings.json. No consumers yet."
```

---

## Task 2: Add file-path and notification-name constants

**Files:**
- Modify: `Library/AppConfiguration.swift`
- Modify: `Library/FilePath.swift`

- [ ] **Step 1: Edit `Library/AppConfiguration.swift` — add the file name constant and notification name**

Replace the contents of the file with:

```swift
import Foundation

public enum AppConfiguration {
    public static let appGroupID = "group.io.proxycat"
    public static let appBundleID = "io.proxycat.Pcat"
    public static let extensionBundleID = "io.proxycat.Pcat.PcatExtension"

    /// Filename of the Unix-domain command socket placed in the App
    /// Group container. The Network Extension's gRPC command server
    /// listens here; the host app's CommandClient dials it.
    public static let commandSocketName = "command.sock"

    /// Filename of the shared runtime-settings JSON. Written by the host
    /// app whenever the user toggles a preference; read directly by the
    /// Go core on every Start / Reload / settings-change so the host and
    /// extension stay in lock-step without shuttling values through IPC.
    public static let settingsFileName = "settings.json"

    /// Filename of the host-only settings JSON. Written by the host app
    /// for features the iOS side owns alone (e.g. on-demand rules
    /// configured on `NETunnelProviderManager`). The Go core never
    /// reads this file.
    public static let hostSettingsFileName = "host_settings.json"

    /// Posted by RuntimeSettings whenever the user changes a runtime
    /// preference. Subscribers (ExtensionEnvironment) react by asking
    /// the running tunnel to re-read settings.json and hot-apply.
    public static let runtimeSettingsDidChange = Notification.Name("io.proxycat.RuntimeSettings.didChange")

    /// Posted by HostSettingsStore whenever the user changes a
    /// host-only preference. Subscribers (ExtensionEnvironment) react by
    /// re-applying the relevant configuration to the
    /// NETunnelProviderManager (e.g. on-demand rules).
    public static let hostSettingsDidChange = Notification.Name("io.proxycat.HostSettings.didChange")
}
```

- [ ] **Step 2: Edit `Library/FilePath.swift` — add `hostSettingsFilePath`**

Find the existing `settingsFilePath` property and insert the new property immediately after it. Locate this block:

```swift
    public static var settingsFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.settingsFileName).path
    }
```

Replace with:

```swift
    public static var settingsFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.settingsFileName).path
    }

    /// Path of the host-only settings JSON. Sits next to
    /// `settings.json` in the App Group root so the same set of paths
    /// configures every persistence consumer. Read/written only by the
    /// host app; the Go core never touches it.
    public static var hostSettingsFilePath: String {
        sharedDirectory.appendingPathComponent(AppConfiguration.hostSettingsFileName).path
    }
```

- [ ] **Step 3: Verify it compiles**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Library/AppConfiguration.swift Library/FilePath.swift
git commit -m "Add host_settings.json path and didChange notification name

Lives next to settings.json in the App Group root. Read/written only
by the host app; the Go core ignores it."
```

---

## Task 3: Add `HostSettingsStore`

**Files:**
- Create: `Library/HostSettingsStore.swift`

- [ ] **Step 1: Create the new file**

```swift
import Combine
import Foundation
import os

/// Single source of truth for host-only preferences (currently the
/// Auto Connect feature; future iOS-side features land here too).
/// Persists to `host_settings.json` in the App Group container.
///
/// Mirrors `RuntimeSettings`: load on init, dropFirst() guards against
/// re-writing what we just loaded, atomic file writes, and a single
/// notification (`hostSettingsDidChange`) posted on every persisted
/// change. Subscribers — currently `ExtensionEnvironment` — react by
/// re-applying the relevant configuration to NETunnelProviderManager.
@MainActor
public final class HostSettingsStore: ObservableObject {
    public static let shared = HostSettingsStore()

    @Published public var autoConnect: AutoConnectConfig

    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "HostSettingsStore")
    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = Self.loadFromDisk()
        self.autoConnect = stored.autoConnect

        // dropFirst skips the publisher's "current value" replay so we
        // don't immediately re-write what we just loaded; subsequent
        // changes from a SwiftUI binding flow through persistAndBroadcast.
        //
        // Persist from the value the publisher emits, not from
        // self.autoConnect: @Published emits in willSet, so reading
        // self.* here returns the *previous* value.
        $autoConnect
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] config in
                self?.persistAndBroadcast(snapshot: HostSettings(autoConnect: config))
            }
            .store(in: &bag)
    }

    private static func loadFromDisk() -> HostSettings {
        let path = FilePath.hostSettingsFilePath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .defaults
        }
        return (try? JSONDecoder().decode(HostSettings.self, from: data)) ?? .defaults
    }

    private func persistAndBroadcast(snapshot: HostSettings) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            // Atomic write: a partial file would make us fall back to
            // defaults on the next launch, which is worse than a stale
            // file.
            try data.write(to: URL(fileURLWithPath: FilePath.hostSettingsFilePath), options: .atomic)
        } catch {
            Self.logger.error("could not persist host settings: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: AppConfiguration.hostSettingsDidChange, object: self)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Library/HostSettingsStore.swift
git commit -m "Add HostSettingsStore mirroring RuntimeSettings shape

Loads host_settings.json on init, persists atomically on @Published
changes, and posts hostSettingsDidChange. No consumers yet."
```

---

## Task 4: Teach `ExtensionProfile` to apply on-demand rules

**Files:**
- Modify: `Library/ExtensionProfile.swift`

- [ ] **Step 1: Add `applyAutoConnect(_:)` and helpers to `ExtensionProfile`**

Open `Library/ExtensionProfile.swift`. Locate the `reload()` method and insert the new method **after** it (so it sits with the other public manager-mutation methods). Add the static helpers at the bottom of the class, just before the `private func attachObserver` declaration.

Insert after `public func reload() async throws { ... }`:

```swift
    /// Pushes the user's Auto Connect configuration onto the
    /// NETunnelProviderManager: flips `isOnDemandEnabled` and rebuilds
    /// the `onDemandRules` array, then persists. Idempotent — if the
    /// derived state already matches what the manager has, the
    /// `saveToPreferences` is still cheap. Safe to call while
    /// connected; iOS picks up the new rules on the next network
    /// change without restarting the tunnel.
    public func applyAutoConnect(_ config: AutoConnectConfig) async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = config.enabled
        manager.onDemandRules = Self.buildOnDemandRules(from: config)
        try await manager.saveToPreferences()
    }
```

Then, immediately before the existing `private func attachObserver(_ manager: NETunnelProviderManager) {`, insert:

```swift
    private static func buildOnDemandRules(from c: AutoConnectConfig) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []

        // SSID-specific rules first; first-match wins, so they always
        // override the cellular and fallback rules below.
        for r in c.ssidRules where !r.ssid.isEmpty {
            let rule = makeOnDemandRule(for: r.action)
            rule.interfaceTypeMatch = .wiFi
            rule.ssidMatch = [r.ssid]
            rules.append(rule)
        }

        let cell = makeOnDemandRule(for: c.cellular)
        cell.interfaceTypeMatch = .cellular
        rules.append(cell)

        // Final fallback — `.any` matches anything not yet matched,
        // including Wi-Fi networks the user has not named.
        let fallback = makeOnDemandRule(for: c.fallback)
        fallback.interfaceTypeMatch = .any
        rules.append(fallback)

        return rules
    }

    private static func makeOnDemandRule(for action: AutoConnectAction) -> NEOnDemandRule {
        switch action {
        case .connect:    return NEOnDemandRuleConnect()
        case .disconnect: return NEOnDemandRuleDisconnect()
        case .ignore:     return NEOnDemandRuleIgnore()
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Library/ExtensionProfile.swift
git commit -m "Add ExtensionProfile.applyAutoConnect for on-demand rules

Translates AutoConnectConfig into NEOnDemandRule[] (SSID rules first,
then cellular, then any-interface fallback) and saves to the manager's
preferences. Idempotent and safe while connected."
```

---

## Task 5: Wire `ExtensionEnvironment` to apply on bootstrap and on store changes

**Files:**
- Modify: `Library/ExtensionEnvironment.swift`

- [ ] **Step 1: Add the host-settings observer, the apply method, and surface errors**

Open `Library/ExtensionEnvironment.swift`.

(a) Below the existing `private var settingsObserver: NSObjectProtocol?` line, add a new stored property:

```swift
    private var hostSettingsObserver: NSObjectProtocol?
```

(b) Below the existing `@Published public var reloadError: String?` line, add:

```swift
    /// Surfaces the most recent on-demand-rule save failure so the
    /// Auto Connect sub view can show an alert.
    @Published public var autoConnectError: String?
```

(c) In `deinit`, alongside the existing observer cleanup, add:

```swift
        if let token = hostSettingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
```

(d) In `bootstrap()`, after `observeRuntimeSettings()` and before `startMemoryPressureWatch()`, add a line that registers the new observer; then, after `applyStatus(profile.status)`, add a line that performs the initial apply. The full updated body:

Locate this existing block:

```swift
    public func bootstrap() async {
        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }
        observeProfileStatus()
        observeActiveContent()
        observeRuntimeSettings()
        startMemoryPressureWatch()
        // Make sure the current state is honored even before the
        // observer's first event fires (e.g. app cold-launches with VPN
        // already connected from a previous session).
        applyStatus(profile.status)
    }
```

Replace it with:

```swift
    public func bootstrap() async {
        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }
        observeProfileStatus()
        observeActiveContent()
        observeRuntimeSettings()
        observeHostSettings()
        startMemoryPressureWatch()
        // Make sure the current state is honored even before the
        // observer's first event fires (e.g. app cold-launches with VPN
        // already connected from a previous session).
        applyStatus(profile.status)
        // Sync the manager's on-demand state with whatever the user
        // last persisted. No-op when the manager already matches; cheap
        // even when not, and it covers the case where the user edits
        // settings while the app was killed.
        await applyAutoConnectFromStore()
    }
```

(e) Just below the existing `observeRuntimeSettings()` function definition, add the new observer registration and the apply helper:

```swift
    private func observeHostSettings() {
        guard hostSettingsObserver == nil else { return }
        hostSettingsObserver = NotificationCenter.default.addObserver(
            forName: AppConfiguration.hostSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.applyAutoConnectFromStore()
            }
        }
    }

    /// Reads the current `AutoConnectConfig` from the store and pushes
    /// it onto the NETunnelProviderManager via `ExtensionProfile`.
    /// Errors surface through `autoConnectError` so the UI can show an
    /// alert; we never throw out of an observer callback.
    private func applyAutoConnectFromStore() async {
        let config = HostSettingsStore.shared.autoConnect
        do {
            try await profile.applyAutoConnect(config)
        } catch {
            autoConnectError = error.localizedDescription
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Library/ExtensionEnvironment.swift
git commit -m "Apply Auto Connect rules on bootstrap and on every store change

Adds a hostSettingsDidChange observer that re-pushes the
AutoConnectConfig onto NETunnelProviderManager. Bootstrap also runs
one initial apply so cold launches honor the persisted state. Save
failures surface via @Published autoConnectError."
```

---

## Task 6: Build the Auto Connect sub view

**Files:**
- Create: `ApplicationLibrary/AutoConnectSettingsView.swift`

- [ ] **Step 1: Create the sub view**

```swift
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
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds. The view is unreachable from any navigation entry yet — that's the next task.

- [ ] **Step 3: Commit**

```bash
git add ApplicationLibrary/AutoConnectSettingsView.swift
git commit -m "Add AutoConnectSettingsView sub view

Master toggle, SSID-rule list with inline action pickers and
swipe-to-delete, cellular and default rows, footer notes covering
the iOS first-connect quirk and case-sensitivity. Disabled until a
profile is active."
```

---

## Task 7: Add the entry point in `SettingsView`

**Files:**
- Modify: `ApplicationLibrary/SettingsView.swift`

- [ ] **Step 1: Insert the navigation link above the existing Advanced section**

Find the existing block at the bottom of `SettingsView`'s `Form`:

```swift
            Section {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
```

Replace with:

```swift
            Section {
                NavigationLink {
                    AutoConnectSettingsView()
                } label: {
                    Label("Auto Connect", systemImage: "wifi.circle")
                }
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
```

- [ ] **Step 2: Verify it compiles**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ApplicationLibrary/SettingsView.swift
git commit -m "Add Settings entry point for Auto Connect

NavigationLink above Advanced; same Section to share the visual
separator. Uses wifi.circle which is available on iOS 17+."
```

---

## Task 8: Sort `Localizable.xcstrings` after Xcode auto-extraction

**Files:**
- Modify: `Localizable.xcstrings` (auto-generated change)

Xcode auto-extracts new `String(localized:)` and `Text("…")` literals into `Localizable.xcstrings` on the next build. The project's commit history shows a convention of sorting the file alphabetically afterward (commit `c18d7c2` "Sort Localizable.xcstrings after Xcode auto-extraction").

- [ ] **Step 1: Trigger extraction by building**

Run: `make sim`
Expected: build succeeds. Xcode merges new keys into `Localizable.xcstrings`.

- [ ] **Step 2: Verify what changed**

Run: `git diff Localizable.xcstrings | head -80`
Expected: new top-level entries for the strings introduced by Tasks 6 and 7. New keys to expect (case-sensitive, exact strings):

- `"Action"`
- `"Add"` (already exists; may be unchanged)
- `"Add SSID"`
- `"Already in the list."`
- `"Auto Connect"`
- `"Cancel"` (already exists; may be unchanged)
- `"Cellular"`
- `"Connect"` (already exists; may be unchanged)
- `"Could not save"`
- `"Default"`
- `"Disconnect"` (already exists; may be unchanged)
- `"Enter the exact Wi-Fi name. iOS matches case-sensitively."`
- `"iOS evaluates SSIDs case-sensitively. The first matching rule wins; networks not listed fall through to the Default action below."`
- `"iOS only auto-connects after you have tapped Connect on the Dashboard at least once on this device."`
- `"Ignore"`
- `"Network name"`
- `"Network name cannot be empty."`
- `"OK"` (already exists; may be unchanged)
- `"Pick a profile first."`
- `"Used for any network not matched above."`
- `"When on, ProxyCat connects or disconnects automatically based on the rules below. When off, use the Dashboard to control the tunnel manually."`
- `"Wi-Fi SSIDs"`

- [ ] **Step 3: Sort the strings table alphabetically**

The `Localizable.xcstrings` file is JSON with a top-level `"strings"` object. Keys must be sorted alphabetically per project convention. Run:

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("Localizable.xcstrings")
data = json.loads(p.read_text())
data["strings"] = dict(sorted(data["strings"].items()))
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
```

Expected: the script runs silently and rewrites the file with sorted keys.

- [ ] **Step 4: Verify the rewrite is well-formed**

Run: `python3 -c "import json; json.load(open('Localizable.xcstrings'))"`
Expected: no output (success; invalid JSON would raise).

- [ ] **Step 5: Build once more to confirm Xcode is still happy with the file**

Run: `make sim`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Localizable.xcstrings
git commit -m "Sort Localizable.xcstrings after Xcode auto-extraction

New keys introduced by the Auto Connect sub view."
```

---

## Task 9: Manual on-device smoke test

**Files:** none

**Why on-device, not simulator:** `NEOnDemandRule` evaluation requires the system to detect real network interface changes (Wi-Fi join/leave, cellular failover). The simulator does not exercise this path.

- [ ] **Step 1: Install the build on a physical iPhone**

Run: `make build` (then deploy via Xcode → Run on the connected device).
Expected: app launches normally; no behavior changes from the previous build until the user touches Auto Connect.

- [ ] **Step 2: Baseline regression — feature off**

Settings → Auto Connect → leave the master switch **off**. Tap Connect on the Dashboard.
Expected: identical behavior to the previous build. iOS Settings → VPN → ProxyCat → On Demand should be **off**.

- [ ] **Step 3: No-op enable**

Toggle Auto Connect on; leave Cellular = Ignore, Default = Ignore, no SSIDs. Disconnect from the Dashboard, change networks (Wi-Fi → Wi-Fi).
Expected: tunnel stays disconnected. No surprise reconnects. iOS Settings → VPN → ProxyCat → On Demand should be **on**.

- [ ] **Step 4: SSID disconnect**

Add an SSID rule for the current Wi-Fi with action **Disconnect**. Tap Connect on the Dashboard once (this "activates" on-demand for iOS). Move to a different Wi-Fi (or toggle airplane mode then re-join the named SSID).
Expected: when re-joining the named SSID, the tunnel disconnects (or refuses to start).

- [ ] **Step 5: Cellular auto-connect**

Set Cellular = **Connect**. Disconnect from Wi-Fi entirely (Settings → Wi-Fi off).
Expected: tunnel reconnects on cellular without user interaction.

- [ ] **Step 6: Manual override**

While on cellular with the tunnel auto-connected, toggle the Auto Connect master switch off in the sub view. Tap Disconnect on the Dashboard.
Expected: tunnel disconnects and stays disconnected.

- [ ] **Step 7: Persistence across launches**

Force-quit the app (App Switcher → swipe up). Re-launch it.
Expected: the master switch state, SSID list, cellular action, and default action all match what was set before quitting. iOS Settings → VPN → ProxyCat → On Demand reflects the same config.

- [ ] **Step 8: Profile gating**

Delete the active profile via Settings → Profiles. Open Auto Connect.
Expected: master switch is greyed out with footer text "Pick a profile first." Pick a profile again → switch becomes interactive.

- [ ] **Step 9: Hot rule edit while connected**

Connect the tunnel manually. Open Auto Connect, change Cellular from Connect to Disconnect.
Expected: no tunnel restart. Verify by leaving the dashboard view; the connection indicator does not blip.

- [ ] **Step 10: If any step regresses, do NOT commit further code; capture the failure and fix before declaring the plan done.**

---

## Self-Review Notes

(Filled in during plan-writing self-review.)

- **Spec coverage:**
  - Data model & translation → Task 1, Task 4.
  - Persistence (`host_settings.json`, store, notification) → Tasks 2 + 3.
  - VPN integration (`applyAutoConnect`, bootstrap + observer) → Tasks 4 + 5.
  - UI (sub view, entry point) → Tasks 6 + 7.
  - Localization → Task 8.
  - Test plan → Task 9.
- **Placeholder scan:** all code blocks contain real Swift; no "TODO", no "Add appropriate error handling".
- **Type consistency:** `AutoConnectAction.{connect, disconnect, ignore}` and `SSIDRule(ssid:, action:)` are referenced identically across Tasks 1, 4, and 6. `HostSettingsStore.shared.autoConnect` is the single access path used in Tasks 5 and 6.
- **No-test-target adaptation:** verification is `make sim` after each code task plus the on-device smoke test in Task 9. Stated upfront in the testing note.
