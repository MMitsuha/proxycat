# Auto Connect — Design

Add a Settings sub view that auto-connects or disconnects ProxyCat based
on the network the device is on: a list of specific Wi-Fi SSIDs, an
action for cellular, and a fallback default action for everything else.
The feature is gated by a master switch.

Implementation rests entirely on iOS's `NEOnDemandRule` mechanism —
rules are evaluated by the system whenever the network changes, so we
don't need any background daemon, location services, or the
`Access WiFi Information` entitlement.

## Goals

- One simple sub view in Settings: master switch, list of SSID rules,
  cellular action, fallback default action.
- All persisted state lives in a host-only JSON file with room for
  future host-only features.
- Settings changes apply to the running tunnel without requiring
  disconnect/reconnect.
- Manual control is preserved: tapping Disconnect on the dashboard
  still stops the tunnel; the user toggles the master switch off if
  they want to stay disconnected.

## Non-goals

- DNS-domain / DNS-server / probe-URL matching (sing-box-for-apple has
  these; not part of this iteration).
- Per-SSID rule reordering — rule order is a system-driven detail
  (SSID rules first, then cellular, then fallback) that the user
  doesn't need to manage.
- Reading the device's currently connected SSID to suggest entries
  (would require the `Access WiFi Information` entitlement and
  Location Services authorization — not worth it for a quality-of-life
  affordance).
- Cross-platform (macOS) variants — this project is iOS only today.

## Data model

```swift
public enum AutoConnectAction: Int, Codable, CaseIterable, Sendable {
    case ignore = 0
    case connect = 1
    case disconnect = 2
}

public struct SSIDRule: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var ssid: String
    public var action: AutoConnectAction
}

public struct AutoConnectConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var ssidRules: [SSIDRule]
    public var cellular: AutoConnectAction
    public var fallback: AutoConnectAction

    public static let defaults = AutoConnectConfig(
        enabled: false,
        ssidRules: [],
        cellular: .ignore,
        fallback: .ignore
    )
}

public struct HostSettings: Codable, Equatable, Sendable {
    public var autoConnect: AutoConnectConfig

    public static let defaults = HostSettings(autoConnect: .defaults)
}
```

`HostSettings` is the umbrella container — today it carries only
`autoConnect`, but new host-only features become new fields on this
struct, not new files.

### Translation to `NEOnDemandRule[]`

`AutoConnectConfig` translates to a flat rule list, evaluated top to
bottom by iOS:

1. One rule per `SSIDRule` (in the order the user added them):
   - Action → matching `NEOnDemandRule` subclass (Connect/Disconnect/Ignore).
   - `interfaceTypeMatch = .wiFi`
   - `ssidMatch = [ssid]`
2. One rule for cellular:
   - Action → matching subclass.
   - `interfaceTypeMatch = .cellular`
3. One final fallback rule:
   - Action → matching subclass.
   - `interfaceTypeMatch = .any` (catches anything not yet matched,
     including unnamed Wi-Fi).

First-match wins; SSID rules come first so they always override the
fallback.

## Persistence

A new file `host_settings.json` lives next to the existing
`settings.json` in the App Group container. The two files have
distinct contracts:

| File | Contract |
| --- | --- |
| `settings.json` | Read directly by the Go core on every Start / Reload. Mutating it must keep the schema the Go side expects. |
| `host_settings.json` | Read only by the iOS host app (when configuring `NETunnelProviderManager.onDemandRules`). The Go core never touches it. |

Keeping them separate avoids polluting the host↔core contract with
fields the core has no opinion on.

### `Library/HostSettingsStore.swift`

Mirrors the existing `Library/RuntimeSettings.swift` pattern:

- `@MainActor public final class HostSettingsStore: ObservableObject`
- `public static let shared = HostSettingsStore()`
- `@Published public var autoConnect: AutoConnectConfig`
- Loads `host_settings.json` at init; falls back to `HostSettings.defaults`
  on missing/corrupt file.
- A Combine pipeline on `$autoConnect` (skipping the initial replay)
  writes the snapshot atomically and posts
  `AppConfiguration.hostSettingsDidChange`.

The notification name lives in `Library/AppConfiguration.swift`:

```swift
public static let hostSettingsDidChange = Notification.Name(
    "io.proxycat.HostSettings.didChange"
)
```

`Library/FilePath.swift` gains:

```swift
public static var hostSettingsFilePath: String {
    workingDirectory.appendingPathComponent("host_settings.json").path
}
```

## VPN integration

### `Library/ExtensionProfile.swift`

One new method:

```swift
public func applyAutoConnect(_ config: AutoConnectConfig) async throws {
    guard let manager else { return }
    manager.isOnDemandEnabled = config.enabled
    manager.onDemandRules = Self.buildRules(from: config)
    try await manager.saveToPreferences()
}

private static func buildRules(from c: AutoConnectConfig) -> [NEOnDemandRule] {
    var rules: [NEOnDemandRule] = []
    for r in c.ssidRules where !r.ssid.isEmpty {
        let rule = makeRule(for: r.action)
        rule.interfaceTypeMatch = .wiFi
        rule.ssidMatch = [r.ssid]
        rules.append(rule)
    }
    let cell = makeRule(for: c.cellular)
    cell.interfaceTypeMatch = .cellular
    rules.append(cell)
    let any = makeRule(for: c.fallback)
    any.interfaceTypeMatch = .any
    rules.append(any)
    return rules
}

private static func makeRule(for action: AutoConnectAction) -> NEOnDemandRule {
    switch action {
    case .connect:    return NEOnDemandRuleConnect()
    case .disconnect: return NEOnDemandRuleDisconnect()
    case .ignore:     return NEOnDemandRuleIgnore()
    }
}
```

### `Library/ExtensionEnvironment.swift`

Adds a `hostSettingsDidChange` observer alongside the existing
`runtimeSettingsDidChange` observer. Two apply triggers:

1. **After `profile.load()`** during `bootstrap()` — synchronizes the
   manager with stored config on cold launch (no-op if both already
   match, but cheap and idempotent via `saveToPreferences`).
2. **On `hostSettingsDidChange`** — re-applies after every UI edit.

Rules are intentionally **not** re-applied inside `start()`. Setting
`manager.isEnabled = true` and `manager.onDemandRules = ...` in the
same save round-trip can race; bootstrap + change-observer covers the
real cases without that risk.

A `reloadError`-style `@Published var autoConnectError: String?`
surfaces save failures (rare, but possible if the system rejects a
malformed rule) so the sub view can show an alert instead of failing
silently.

## UI — `ApplicationLibrary/AutoConnectSettingsView.swift`

```
Auto Connect                            [ON ●]
  When on, ProxyCat connects or disconnects
  automatically based on the rules below.
  (When off, manual control via the Dashboard.)

Wi-Fi SSIDs                                          ← only when enabled
  Home Wi-Fi                       [Disconnect ▾]
  Cafe                             [Connect ▾]
  + Add SSID
  iOS evaluates SSIDs case-sensitively. The first
  matching rule wins; networks not listed fall through
  to the Default action below.

Cellular                            [Connect ▾]      ← only when enabled

Default                             [Ignore ▾]       ← only when enabled
  Used for any network not matched above.

Footer (always visible):
  iOS only auto-connects after you've tapped Connect
  on the Dashboard at least once on this device.
```

### Components

- **Master switch** — `Toggle` bound to `store.autoConnect.enabled`.
  Disabled (greyed) with hint "Pick a profile first." when
  `ProfileStore.shared.active == nil`.
- **SSID row** — `HStack { Text(ssid); Spacer(); Picker action }`
  inside a `ForEach`. Swipe-to-delete via `.onDelete`. Uses
  `Picker.menu` style.
- **+ Add SSID** — last row in the section, opens a `.alert` with a
  single `TextField`. Validation:
  - Trims whitespace; rejects empty.
  - Rejects duplicates with inline error in the alert.
  Action defaults to `.connect` for new entries; user changes via the
  inline picker on the row.
- **Cellular** / **Default** — two single-row sections, each a
  `Picker.menu` for `Connect / Disconnect / Ignore`.

### Entry point in `SettingsView`

A new section above "Advanced":

```swift
Section {
    NavigationLink {
        AutoConnectSettingsView()
    } label: {
        Label("Auto Connect", systemImage: "wifi.circle")
    }
}
```

## Edge cases

- **No active profile** — master switch greyed; toggling is a no-op
  until a profile is active. Rationale: iOS rejects on-demand starts
  when the manager has no profile pointer. Avoid letting the user
  arm the feature into a state that will fail silently.
- **Empty / whitespace SSID** — rejected at input time; never reaches
  the rule list.
- **Duplicate SSID** — rejected at input time. (We don't dedupe
  silently because the user might have meant to edit an existing
  rule's action.)
- **Master switch off** — sets `isOnDemandEnabled = false` but preserves
  `ssidRules` / `cellular` / `fallback` so flipping back on restores
  prior state.
- **Manual disconnect** (Dashboard) — same as today: just stops the
  tunnel. If a Connect rule matches, iOS reconnects. The user knows
  to flip the master switch off if they want to stay disconnected.
- **SSID case sensitivity** — iOS does exact match. Document in the
  footer; don't lowercase.
- **Cold launch** — `bootstrap()` calls `applyAutoConnect(...)` after
  `profile.load()` so the manager always reflects the stored snapshot
  (handles the case of editing settings on one device and reinstalling
  on another, App Group restored).
- **App Group survives reinstall** — `host_settings.json` lives in the
  shared container; rules persist across reinstalls just like
  profiles.

## Files

### New

- `Library/AutoConnect.swift` — `AutoConnectAction`, `SSIDRule`,
  `AutoConnectConfig`, `HostSettings` types.
- `Library/HostSettingsStore.swift` — store, mirroring `RuntimeSettings`.
- `ApplicationLibrary/AutoConnectSettingsView.swift` — the sub view.

### Edited

- `Library/FilePath.swift` — add `hostSettingsFilePath`.
- `Library/AppConfiguration.swift` — add `hostSettingsDidChange`.
- `Library/ExtensionProfile.swift` — add `applyAutoConnect(_:)`.
- `Library/ExtensionEnvironment.swift` — observe `hostSettingsDidChange`;
  apply on bootstrap and on each change.
- `ApplicationLibrary/SettingsView.swift` — add the `NavigationLink`
  above "Advanced".
- `Localizable.xcstrings` — new strings (extracted by Xcode; commit
  alphabetized per project convention).

## Test plan (manual)

The project has no unit-test target; verification is on-device.

1. **Baseline** — cold launch, master switch off: behaves identically
   to current build (no `isOnDemandEnabled` set, no rules).
2. **No-op enable** — flip the switch on with empty rules and both
   defaults at *Ignore*: no automatic connect/disconnect occurs.
3. **SSID disconnect** — add an SSID rule for the test Wi-Fi with
   action *Disconnect*; tap Connect on the Dashboard once to activate
   on-demand; switch to that Wi-Fi → tunnel disconnects (or stays
   disconnected on cold connect).
4. **Cellular auto-connect** — set Cellular = *Connect*; switch off
   Wi-Fi → tunnel reconnects on cellular.
5. **Manual override** — flip master switch off → manual control is
   restored, no surprise reconnects.
6. **Persistence** — force-quit and relaunch → state still in place;
   confirm via iOS Settings → VPN → ProxyCat → On Demand that the
   rules match.
7. **Profile gating** — delete the active profile → master switch
   greys with the "Pick a profile first." hint. Pick a profile →
   switch becomes interactive.
8. **Reload while connected** — connect tunnel, edit a rule → no
   tunnel restart; iOS picks up the new rule list on next network
   change. (`saveToPreferences` is sufficient; we don't trigger
   `profile.reload()` for this.)
