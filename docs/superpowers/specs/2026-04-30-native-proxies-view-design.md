# Native Proxies View — Design

Status: approved (scope), pending implementation
Date: 2026-04-30

## Goal

Add a SwiftUI sub-view, pushed from the dashboard, that lets the user select proxies and run group health-checks — replacing the need to open metacubexd in a browser for the most common operation.

The view replicates the **core** of metacubexd's proxy select page only:

- proxy groups (Selector and similar) with their nodes,
- node selection,
- per-node latency,
- group health-check button.

Out of scope for v1: providers tab, sort/display options modal, card vs list toggle, two-column layout, preview bars/dots, node recommendation, batch-test-all.

## Transport

Use mihomo's REST controller at `http://127.0.0.1:9090`.

The controller is already enabled by default (`libmihomo/binding.go:124`), bound to loopback only, with `Secret = ""` and CORS restricted to loopback. The host app process can reach 127.0.0.1:9090 over loopback once the tunnel is active — the existing "Open Web UI" link on the dashboard relies on this same fact (`ApplicationLibrary/DashboardView.swift:63`).

**Auth assumption — load-bearing.** `binding.go:122,125` unconditionally overwrites `cfg.Controller.Secret = ""` regardless of what the user-supplied YAML asked for, in both branches of the `DisableExternalController` toggle. The Swift client therefore never needs to send an `Authorization` header. If that override is ever removed, this view will start returning 401 and we'll need to plumb a secret through `AppConfiguration`.

Reasons not to extend the gRPC command channel:

- The REST API already exposes everything we need; gRPC would mean new proto messages, Go handlers, and Swift bridge code for ~6 RPCs.
- The architecture comment in `PacketTunnelProvider.swift:71` reserves REST for end-user surfaces. A native UI surfacing the same operations is end-user, not internal IPC.
- Smaller blast radius: no `.xcframework` rebuild needed.

The view is gated on `profile.isConnected && !disableExternalController`, identical to the Web UI link gate. When disabled we show an explanatory empty state.

## API endpoints used

| Operation | Method | Path | Notes |
|---|---|---|---|
| List proxies + groups | GET | `/proxies` | Returns `{ "proxies": { name: Proxy } }`. |
| Select a proxy in a group | PUT | `/proxies/{name}` | Body: `{"name": <node>}`. 204 on success; 400 if not Selector. |
| Single-node delay test | GET | `/proxies/{name}/delay?url=&timeout=` | Returns `{ "delay": <ms> }`. Not used in v1 (we only test by group). |
| Group health-check | GET | `/group/{name}/delay?url=&timeout=` | Returns `{ name: delay }` map. After it returns we re-fetch `/proxies` to pick up updated history. |

These are confirmed by reading `mihomo/hub/route/proxies.go` and `mihomo/hub/route/groups.go` plus metacubexd's `composables/useApi.ts`.

### Defaults

- `url`: `http://www.gstatic.com/generate_204` (matches metacubexd's default).
- `timeout`: 5000 ms.

### Selecting a proxy in a group whose `type != Selector`

The controller returns 400 ("Must be a Selector") for non-selector groups (URLTest, Fallback, LoadBalance). The view simply hides the row tap action for those groups; nodes are read-only and only the latency / current selection is shown.

## Data model

Codable models in `Library/MihomoController.swift`:

```swift
struct ProxyDelayPoint: Codable {
    let time: String
    let delay: Int
}

struct Proxy: Codable {
    let name: String
    let type: String          // "Selector", "URLTest", "Direct", ...
    let now: String?          // currently selected child (groups only)
    let all: [String]?        // child names (groups only)
    let history: [ProxyDelayPoint]
    let testUrl: String?
    let timeout: Int?
    let hidden: Bool?
    let udp: Bool?
    let xudp: Bool?
    let tfo: Bool?
}

struct ProxiesResponse: Codable { let proxies: [String: Proxy] }
struct DelayResponse:   Codable { let delay: Int }
```

`Proxy.history.last?.delay` is the per-node latency we render. `0` or missing = unknown.

## Architecture

Three new types, no shared singletons.

### `Library/MihomoController.swift`

Stateless URLSession wrapper. All methods are `async throws`, body decoded with `JSONDecoder()`.

```swift
public struct MihomoController {
    public init(baseURL: URL = URL(string: "http://127.0.0.1:9090")!,
                session: URLSession = .shared) { … }
    public func proxies() async throws -> [String: Proxy]
    public func select(group: String, name: String) async throws
    public func groupDelay(name: String, url: String, timeoutMs: Int) async throws -> [String: Int]
}
```

Errors thrown:

- `MihomoControllerError.requestFailed(status: Int, body: String)` — non-2xx response.
- `MihomoControllerError.transport(URLError)` — connection refused / timeout.
- `MihomoControllerError.decoding(Error)` — JSON shape mismatch.

URLRequest timeout: 5s for `proxies` and `select`; for `groupDelay` we set the request timeout to `timeoutMs + 2000` so the slow path still has time to return.

### `Library/ProxiesStore.swift`

`@MainActor public final class ProxiesStore: ObservableObject`. View-model.

State:

```swift
@Published private(set) var groups: [Proxy]                  // selectable groups, sorted
@Published private(set) var nodeMap: [String: Proxy]         // name → Proxy (for latency lookup)
@Published private(set) var loadError: String?
@Published private(set) var isRefreshing: Bool
@Published private(set) var groupTesting: Set<String>
@Published private(set) var selecting: Set<String>           // <group>/<node> pair, used to dim row
```

Methods:

- `func refresh() async` — fetch `/proxies`, separate groups (those with `all`) from nodes, sort groups by their position in `proxies["GLOBAL"].all` (matches metacubexd ordering), keep nodes in `nodeMap`. Sets `loadError` on failure.
- `func select(group: Proxy, name: String) async` — guard `group.type == "Selector"`. Insert `"<group>/<name>"` into `selecting` (dims the row while in flight), call controller, then `await refresh()`. Errors surface in `loadError`.
- `func testGroup(_ group: Proxy) async` — insert into `groupTesting`, call controller, then `await refresh()`. Errors surface in `loadError`.

The store is **owned by the view** (`@StateObject`). It holds a `MihomoController`. No global singleton — each appearance of the view starts fresh; `MainView`'s tab switching disposes the store.

### `ApplicationLibrary/ProxiesView.swift`

Single SwiftUI view. Top-level structure:

```swift
public struct ProxiesView: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @AppStorage(AppConfiguration.disableExternalControllerKey)
    private var disableExternalController = false
    @StateObject private var store = ProxiesStore()

    public var body: some View {
        Group {
            if !profile.isConnected { unavailable("Not connected") }
            else if disableExternalController { unavailable("Web Controller is off") }
            else { content }
        }
        .navigationTitle("Proxies")
        .task { await store.refresh() }
    }
}
```

`content` is a `List` with one `Section` per group. Section header uses a custom view (group name, type badge, current `now`, group-test button with spinner). Section rows are nodes (name + latency pill + checkmark when selected). The whole list is `.refreshable { await store.refresh() }`.

Latency pill colors (matches metacubexd's quality map default):

- gray `< 1` (unknown / not tested),
- green `< 300`,
- yellow `< 800`,
- red `≥ 800`.

A toolbar trailing button refreshes everything (`store.refresh()`).

### Dashboard hook

In `ApplicationLibrary/DashboardView.swift`, immediately under the existing "Open Web UI" `Link`, add:

```swift
NavigationLink {
    ProxiesView()
} label: {
    HStack(spacing: 6) {
        Image(systemName: "globe.asia.australia")
        Text("Proxies")
        Spacer()
        Image(systemName: "chevron.right").font(.caption)
    }
    .font(.subheadline)
}
```

Gated by the same condition as the Web UI link: `profile.isConnected && !disableExternalController`. Both can coexist — Web UI for power users, the native row for the common select-and-go case.

## Error handling

| Condition | UI |
|---|---|
| VPN off | Empty state with "Connect first" message and a tunnel icon. |
| Controller disabled in Settings | Empty state pointing the user at Settings. |
| Connection refused (controller still spinning up) | Error view with a manual Retry button. Auto-retry deferred — the user almost always re-enters the view *after* the tunnel is fully up, and the spinner-then-error transition is fine. |
| 404 on PUT (group/name vanished after a config reload) | Toast-style error, then `refresh()`. |
| 400 on PUT (non-Selector group) | Should not happen — the row tap is disabled for non-Selectors. Defensive: log and ignore. |

## Testing

This codebase has no unit-test infrastructure today (sing-box-for-apple style — manual smoke through the iOS simulator). Verification plan:

1. Run the app in the simulator with a multi-group profile (sample-profile.yaml has two Selector groups).
2. Connect, navigate Dashboard → Proxies, confirm groups list renders with current selection.
3. Tap an alternative node in a Selector group; confirm checkmark moves and latency renders.
4. Tap the group health-check button; confirm spinner runs and latencies update.
5. Disable Web Controller in Settings, return to dashboard; the Proxies row hides and the view shows the disabled empty state if entered via deep link.
6. Disconnect the VPN; the Proxies row hides.

If we add unit tests later, `MihomoController` is the right seam — its `URLSession` parameter is injectable.

## Localization

New user-facing strings (added to `Localizable.xcstrings`):

- "Proxies" (nav title + dashboard link)
- "Connect first to manage proxies"
- "Web Controller is off"
- "Test latency"
- "No groups available"

## Open questions

None. Ready for implementation plan.
