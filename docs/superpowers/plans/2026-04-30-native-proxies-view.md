# Native Proxies View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a SwiftUI sub-view, pushed from the dashboard, that lists proxy groups, lets the user select a node, and runs group health-checks against mihomo's REST controller at `127.0.0.1:9090`.

**Architecture:** Three new types — a stateless `MihomoController` (URLSession client), a `@MainActor` `ProxiesStore` (view-model), and a `ProxiesView` (SwiftUI). Dashboard gets a single `NavigationLink` row gated behind `isConnected && !disableExternalController`, identical to the existing "Open Web UI" link. No proto / Go / xcframework changes.

**Tech Stack:** Swift 5.10, SwiftUI, NetworkExtension, iOS 17+. URLSession.shared for HTTP. `Codable` for JSON. `@StateObject` / `@EnvironmentObject` for state.

**Spec:** `docs/superpowers/specs/2026-04-30-native-proxies-view-design.md`

**Testing note (adaptation):** This codebase has zero XCTest infrastructure. Adding one for four helper functions would be scope creep, and SwiftUI views in iOS apps are conventionally smoke-tested in the simulator. Verification therefore relies on:
1. **Compilation** after each task (`make sim` succeeds = the type contract holds), and
2. **Manual smoke test** in Task 7, exercising every code path defined in the spec.
The code is structured to *make* unit tests easy if added later: `MihomoController` accepts an injectable `URLSession`; pure helpers (`latencyTier`, group sort) are static and side-effect free.

---

## File Structure

| File | Status | Purpose |
|---|---|---|
| `Library/MihomoController.swift` | NEW | URLSession-based REST client. Models + 3 endpoint methods + error type. |
| `Library/ProxiesStore.swift` | NEW | `@MainActor ObservableObject` view-model. Holds groups/nodes, refresh/select/test methods. |
| `ApplicationLibrary/ProxiesView.swift` | NEW | SwiftUI list of groups; pushed from dashboard. |
| `ApplicationLibrary/DashboardView.swift` | MODIFY | Add `NavigationLink` row under the existing Web UI link. |
| `Localizable.xcstrings` | MODIFY | Add 5 new strings + zh-Hans translations. |

`Library/` is the underlying framework, depended on by `ApplicationLibrary/` and `PcatExtension/`. The new networking + view-model pieces live in `Library/` so they are available to both the host app and (if ever needed) a widget extension. The view itself is `ApplicationLibrary/`-only because it imports SwiftUI app conventions used by the host.

The xcodegen project is regenerated automatically — newly added `.swift` files inside the `Library/` and `ApplicationLibrary/` directories are picked up by the existing folder-reference sources (`project.yml:36-39, 71-73`). No `project.yml` edits needed; **only re-run `make project` if a build fails to find a new file**.

---

## Task 1: Add MihomoController

**Files:**
- Create: `Library/MihomoController.swift`

- [ ] **Step 1: Create the file with imports, models, and error type**

```swift
import Foundation

// MARK: - Models (mirror mihomo's REST shapes; see hub/route/proxies.go)

public struct ProxyDelayPoint: Codable, Hashable {
    public let time: String
    public let delay: Int
}

public struct Proxy: Codable, Hashable {
    public let name: String
    /// "Selector", "URLTest", "Direct", "Reject", "Fallback", "LoadBalance", ...
    public let type: String
    /// Currently selected child name (groups only).
    public let now: String?
    /// Child names (groups only).
    public let all: [String]?
    public let history: [ProxyDelayPoint]
    public let testUrl: String?
    public let timeout: Int?
    public let hidden: Bool?
    public let udp: Bool?
    public let xudp: Bool?
    public let tfo: Bool?

    /// Last delay sample, or nil if untested. 0 in the JSON means "test failed"
    /// — surfaced as `nil` so the UI shows it as unknown rather than "0 ms".
    public var latestDelay: Int? {
        guard let last = history.last, last.delay > 0 else { return nil }
        return last.delay
    }

    public var isGroup: Bool { all?.isEmpty == false }
    public var isSelector: Bool { type == "Selector" }
}

public struct ProxiesResponse: Codable {
    public let proxies: [String: Proxy]
}

public struct DelayResponse: Codable {
    public let delay: Int
}

// MARK: - Errors

public enum MihomoControllerError: LocalizedError {
    case requestFailed(status: Int, body: String)
    case transport(URLError)
    case decoding(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let body):
            return "Controller returned HTTP \(status): \(body.prefix(160))"
        case .transport(let err):
            return err.localizedDescription
        case .decoding(let err):
            return "Could not decode controller response: \(err.localizedDescription)"
        case .invalidResponse:
            return "Controller returned a non-HTTP response"
        }
    }
}

// MARK: - Client

/// Talks to mihomo's external-controller (default `http://127.0.0.1:9090`).
///
/// The controller is bound to loopback by `libmihomo/binding.go` and its
/// secret is forced empty there too (binding.go:122,125), so the host app
/// reaches it without auth as long as the tunnel is up. See the design
/// spec for the auth-assumption caveat.
public struct MihomoController {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:9090")!
    public static let defaultTestURL = "http://www.gstatic.com/generate_204"
    public static let defaultTimeoutMs = 5000

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
    }

    // Endpoint methods added in subsequent steps.
}
```

- [ ] **Step 2: Add `proxies()`**

Append inside the `MihomoController` struct:

```swift
    /// `GET /proxies` → `{ "proxies": { name: Proxy } }`.
    public func proxies() async throws -> [String: Proxy] {
        let req = makeRequest(path: "proxies", timeout: 5)
        let data = try await perform(req)
        do {
            return try decoder.decode(ProxiesResponse.self, from: data).proxies
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }
```

- [ ] **Step 3: Add `select()`**

Append inside the struct:

```swift
    /// `PUT /proxies/{group}` body `{"name": <node>}`. 204 on success.
    /// 400 if the group is not a Selector (URLTest/Fallback/LoadBalance).
    public func select(group: String, name: String) async throws {
        var req = makeRequest(path: "proxies/\(escape(group))", timeout: 5)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await perform(req)
    }
```

- [ ] **Step 4: Add `groupDelay()`**

Append inside the struct:

```swift
    /// `GET /group/{name}/delay?url=&timeout=` → `{ name: delay }` map.
    /// We re-fetch `/proxies` after this to pick up updated histories.
    public func groupDelay(
        name: String,
        url: String = defaultTestURL,
        timeoutMs: Int = defaultTimeoutMs
    ) async throws -> [String: Int] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("group/\(escape(name))/delay"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: String(timeoutMs)),
        ]
        // Give the request a hair more time than the per-node timeout
        // because the server runs them concurrently and still needs to
        // serialize the result.
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000 + 2
        let data = try await perform(req)
        do {
            return try decoder.decode([String: Int].self, from: data)
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }
```

- [ ] **Step 5: Add the private helpers**

Append inside the struct:

```swift
    // MARK: - Private

    private func makeRequest(path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        return req
    }

    /// Percent-encode a path segment. mihomo's `parseProxyName` middleware
    /// uses `getEscapeParam`, which round-trips a URL-encoded segment.
    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MihomoControllerError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw MihomoControllerError.requestFailed(status: http.statusCode, body: body)
            }
            return data
        } catch let err as MihomoControllerError {
            throw err
        } catch let err as URLError {
            throw MihomoControllerError.transport(err)
        }
    }
```

- [ ] **Step 6: Verify it compiles**

Run from the worktree root:

```bash
make sim
```

Expected: build succeeds. (If the project was never generated, run `make project` first; if `Libmihomo.xcframework` is missing, the sim build will skip linking — that's fine for now since this file doesn't depend on it.)

If you see "No such module 'Foundation'" or "cannot find Proxy in scope", re-run `make project` to refresh the xcodegen-generated project file.

- [ ] **Step 7: Commit**

```bash
git add Library/MihomoController.swift
git commit -m "$(cat <<'EOF'
Add MihomoController for talking to the external-controller REST API

Stateless URLSession client with Codable models matching mihomo's
hub/route/proxies.go output. Backs the upcoming native proxies view.
EOF
)"
```

---

## Task 2: Add ProxiesStore

**Files:**
- Create: `Library/ProxiesStore.swift`

- [ ] **Step 1: Create the file with state and `init`**

```swift
import Combine
import Foundation

/// View-model for `ProxiesView`. One instance per view appearance; not a
/// shared singleton. Holds proxy-group metadata plus in-flight bookkeeping
/// so the UI can reflect "selecting…" and "testing…" states.
@MainActor
public final class ProxiesStore: ObservableObject {
    @Published public private(set) var groups: [Proxy] = []
    @Published public private(set) var nodeMap: [String: Proxy] = [:]
    @Published public private(set) var loadError: String?
    @Published public private(set) var isRefreshing: Bool = false
    /// Group names with an in-flight health-check.
    @Published public private(set) var groupTesting: Set<String> = []
    /// `"<group>/<node>"` pairs with an in-flight selection.
    @Published public private(set) var selecting: Set<String> = []

    private let controller: MihomoController

    public init(controller: MihomoController = MihomoController()) {
        self.controller = controller
    }

    // Methods added in subsequent steps.
}

private func selectingKey(group: String, node: String) -> String {
    "\(group)/\(node)"
}
```

- [ ] **Step 2: Add `refresh()`**

Append inside the class:

```swift
    /// `GET /proxies` and split the response into groups vs nodes. Groups
    /// are sorted by `proxies["GLOBAL"].all`, matching metacubexd —
    /// otherwise the order is whatever Go's map iteration produced this
    /// run, which would shuffle on every refresh.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let proxies = try await controller.proxies()
            let sortIndex = (proxies["GLOBAL"]?.all ?? []) + ["GLOBAL"]
            let groupList = proxies.values
                .filter { $0.isGroup && !($0.hidden ?? false) }
                .sorted { lhs, rhs in
                    let li = sortIndex.firstIndex(of: lhs.name) ?? Int.max
                    let ri = sortIndex.firstIndex(of: rhs.name) ?? Int.max
                    if li != ri { return li < ri }
                    return lhs.name < rhs.name
                }
            self.groups = groupList
            self.nodeMap = proxies
            self.loadError = nil
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
```

- [ ] **Step 3: Add `select()` and `testGroup()`**

Append inside the class:

```swift
    /// Pick a node inside a Selector group. Non-selector groups are
    /// guarded out — the view also hides the tap action for them, but we
    /// keep the guard here so a misuse of the API is silent rather than
    /// throwing a 400 the user has to read.
    public func select(group: Proxy, name: String) async {
        guard group.isSelector else { return }
        let key = selectingKey(group: group.name, node: name)
        selecting.insert(key)
        defer { selecting.remove(key) }
        do {
            try await controller.select(group: group.name, name: name)
            await refresh()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Run a health-check on every node in a group. Re-fetches `/proxies`
    /// after to pick up the updated `history` arrays — the delay endpoint
    /// returns just `name → ms` and we want consistent UI state.
    public func testGroup(_ group: Proxy) async {
        groupTesting.insert(group.name)
        defer { groupTesting.remove(group.name) }
        do {
            _ = try await controller.groupDelay(name: group.name)
            await refresh()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    public func isSelecting(group: String, node: String) -> Bool {
        selecting.contains(selectingKey(group: group, node: node))
    }
```

- [ ] **Step 4: Verify it compiles**

```bash
make sim
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Library/ProxiesStore.swift
git commit -m "$(cat <<'EOF'
Add ProxiesStore view-model for proxy-group state

Wraps MihomoController and exposes refresh/select/testGroup for the
upcoming SwiftUI view. Keeps in-flight bookkeeping so rows can dim and
the test button can spin without leaking through to the controller.
EOF
)"
```

---

## Task 3: Build ProxiesView skeleton with empty/error states

**Files:**
- Create: `ApplicationLibrary/ProxiesView.swift`

- [ ] **Step 1: Create the file with the view, gating, and helpers**

```swift
import Library
import SwiftUI

public struct ProxiesView: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @AppStorage(AppConfiguration.disableExternalControllerKey)
    private var disableExternalController = false
    @StateObject private var store = ProxiesStore()

    public init() {}

    public var body: some View {
        Group {
            if !profile.isConnected {
                empty(
                    symbol: "powerplug.portrait",
                    title: String(localized: "Connect first to manage proxies")
                )
            } else if disableExternalController {
                empty(
                    symbol: "network.slash",
                    title: String(localized: "Web Controller is off")
                )
            } else {
                content
            }
        }
        .navigationTitle("Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        // Filled in by the next task.
        if let err = store.loadError, store.groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.groups.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("groups go here").foregroundStyle(.secondary)
        }
    }

    private func empty(symbol: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
make sim
```

Expected: build succeeds. (`ProxiesView` isn't reachable from the UI yet, but the framework should still link.)

- [ ] **Step 3: Commit**

```bash
git add ApplicationLibrary/ProxiesView.swift
git commit -m "$(cat <<'EOF'
Add ProxiesView skeleton with VPN/controller gating

Empty states for the two ways the view is unreachable; loading and
error placeholders for the connected case. Group rendering comes next.
EOF
)"
```

---

## Task 4: Render group sections and node rows

**Files:**
- Modify: `ApplicationLibrary/ProxiesView.swift`

- [ ] **Step 1: Replace the placeholder `content` body**

Replace the inner branch starting `} else {\n            Text("groups go here")...` (the third arm of the `if let err …` chain) with:

```swift
        } else {
            List {
                ForEach(store.groups, id: \.name) { group in
                    Section {
                        ForEach(group.all ?? [], id: \.self) { name in
                            ProxyRow(
                                name: name,
                                node: store.nodeMap[name],
                                isSelected: group.now == name,
                                isInteractive: group.isSelector,
                                isPending: store.isSelecting(group: group.name, node: name),
                                onTap: {
                                    Task { await store.select(group: group, name: name) }
                                }
                            )
                        }
                    } header: {
                        ProxyGroupHeader(
                            group: group,
                            isTesting: store.groupTesting.contains(group.name),
                            onTest: { Task { await store.testGroup(group) } }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
```

- [ ] **Step 2: Add the `ProxyGroupHeader` subview at the bottom of the file**

Append below the closing brace of `public struct ProxiesView`:

```swift
// MARK: - Group header

private struct ProxyGroupHeader: View {
    let group: Proxy
    let isTesting: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(group.type)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if let now = group.now, !now.isEmpty {
                    Text(now)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onTest) {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stopwatch")
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Test latency"))
            .disabled(isTesting)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 3: Add the `ProxyRow` and `LatencyPill` subviews**

Append below `ProxyGroupHeader`:

```swift
// MARK: - Node row

private struct ProxyRow: View {
    let name: String
    let node: Proxy?
    let isSelected: Bool
    let isInteractive: Bool
    let isPending: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: { if isInteractive { onTap() } }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let type = node?.type {
                        Text(type)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LatencyPill(ms: node?.latestDelay)
            }
            .opacity(isPending ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || isPending)
    }
}

// MARK: - Latency pill

private struct LatencyPill: View {
    let ms: Int?

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        guard let ms else { return "—" }
        return "\(ms) ms"
    }

    /// Same thresholds metacubexd's default `latencyQualityMap` uses.
    private var color: Color {
        guard let ms, ms > 0 else { return .secondary }
        if ms < 300 { return .green }
        if ms < 800 { return .yellow }
        return .red
    }
}
```

- [ ] **Step 4: Verify it compiles**

```bash
make sim
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ApplicationLibrary/ProxiesView.swift
git commit -m "$(cat <<'EOF'
Render proxy groups, node rows, and the latency pill

Sectioned list mirrors metacubexd's core layout: group header with
type badge and a stopwatch button for health-checking the whole group,
rows with latency pill and selected-state checkmark.
EOF
)"
```

---

## Task 5: Hook the view into DashboardView

**Files:**
- Modify: `ApplicationLibrary/DashboardView.swift`

- [ ] **Step 1: Add the `NavigationLink` row**

In `DashboardView.swift`, find the `statusCard` body. Locate the trailing `if profile.isConnected, !disableExternalController, let url = URL(string: "http://127.0.0.1:9090/ui/")` block (around line 63-74 in the current file). Immediately AFTER its closing `}` and BEFORE the closing `}` of the outer `VStack`, add:

```swift
            if profile.isConnected, !disableExternalController {
                NavigationLink {
                    ProxiesView()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.asia.australia")
                        Text("Proxies")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
```

Verify the order in the resulting file: connect button → Web UI link → Proxies link → end of `statusCard` `VStack`.

- [ ] **Step 2: Verify it compiles and the link is reachable**

```bash
make sim
```

Expected: build succeeds. (`ProxiesView` is `public`; `DashboardView` is in the same `ApplicationLibrary` module so no import change is needed.)

- [ ] **Step 3: Commit**

```bash
git add ApplicationLibrary/DashboardView.swift
git commit -m "$(cat <<'EOF'
Add Proxies row to dashboard, gated like the Web UI link

NavigationLink is shown only when the tunnel is connected and the user
hasn't disabled the external controller — same gate as the existing
Open Web UI link, since the new view depends on the same surface.
EOF
)"
```

---

## Task 6: Add localized strings

**Files:**
- Modify: `Localizable.xcstrings`

The five new user-facing strings used in the previous tasks need zh-Hans translations to match the rest of the app (commit 8f8f0d3 added zh-Hans for everything else).

The xcstrings JSON is a flat object under `strings`. Add an entry per string. Each entry has `localizations.zh-Hans.stringUnit.{state, value}`. State is `"translated"` once you fill in `value`. The `en` source comes from the Swift `String(localized:)` calls automatically; you do **not** need to add an `en` entry — only `zh-Hans`.

- [ ] **Step 1: Add the 5 entries**

Open `Localizable.xcstrings` and add these inside the top-level `"strings"` object (preserve alphabetical order — find the right insertion point by string-comparing the key against existing keys):

```json
    "Connect first to manage proxies" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "请先连接后再管理代理"
          }
        }
      }
    },
    "Proxies" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "代理"
          }
        }
      }
    },
    "Retry" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "重试"
          }
        }
      }
    },
    "Test latency" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "测试延迟"
          }
        }
      }
    },
    "Web Controller is off" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "网页控制器已关闭"
          }
        }
      }
    },
```

If there is already an entry for `"Proxies"` or any other key in the file (use a JSON parser or grep first to check), do NOT duplicate it — Xcode treats duplicates as a build error. Skip duplicates and continue with the rest.

- [ ] **Step 2: Validate the file is still valid JSON**

```bash
python3 -c "import json; json.load(open('Localizable.xcstrings'))" && echo "ok"
```

Expected: `ok`. If it prints a `JSONDecodeError`, you broke the bracket structure — find the entry you added and fix the trailing-comma / brace alignment.

- [ ] **Step 3: Build to confirm Xcode accepts the catalog**

```bash
make sim
```

Expected: build succeeds. Xcode silently auto-extracts referenced `String(localized:)` keys at build time; you'll see no warnings if the file is well-formed.

- [ ] **Step 4: Commit**

```bash
git add Localizable.xcstrings
git commit -m "$(cat <<'EOF'
Localize the five new strings used by the proxies view

zh-Hans translations for nav title, the two empty states, the retry
button, and the per-group test-latency accessibility label, matching
the project's existing String Catalog coverage.
EOF
)"
```

---

## Task 7: Manual smoke test

This task has no commit. It exercises the spec's "Testing" section against a real simulator build. Do not skip it.

**Prerequisites:** you have a profile imported in the app (sample-profile.yaml in the repo root works — it has `Proxy` and `Auto` Selector groups).

- [ ] **Step 1: Build and launch in the iOS simulator**

```bash
make sim
xcrun simctl boot "iPhone 15" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/ProxyCat-*/Build/Products/Debug-iphonesimulator/Pcat.app
xcrun simctl launch booted io.proxycat.Pcat
```

If the install line fails because the path glob expands to more than one DerivedData folder, run `ls ~/Library/Developer/Xcode/DerivedData/ | grep ProxyCat` and pick the most recent one.

- [ ] **Step 2: Verify the disconnected state**

In the simulator app, with no VPN connected, navigate to the Dashboard tab. Confirm:
- The "Proxies" row is **not** shown (because `profile.isConnected` is false).

- [ ] **Step 3: Connect and verify the row appears**

Pick a profile, tap Connect. After the status badge turns green, confirm:
- The "Open Web UI" link is shown.
- The "Proxies" `NavigationLink` row is shown directly below it.

- [ ] **Step 4: Open ProxiesView and verify groups render**

Tap the Proxies row. Confirm:
- Title bar reads "Proxies".
- Each Selector group from your profile appears as a section.
- Each section header shows the group name, a "Selector" pill, and the current selection in monospaced caption.
- A stopwatch icon is visible at the right of each header.
- Each row has a circle/checkmark, the node name, the node type, and a latency pill.

- [ ] **Step 5: Select a different node**

In a Selector group, tap a row that is *not* currently selected. Confirm:
- The row dims briefly while the request is in flight.
- After completion, the checkmark moves to the tapped row, and the section header's "now" text updates.

- [ ] **Step 6: Run a group health-check**

Tap the stopwatch button on a section header. Confirm:
- The icon swaps to a small spinner while the test runs (≤7 s including re-fetch).
- After completion, every row's latency pill updates with a colored value (or stays "—" / gray if the node was unreachable).
- The button returns to the stopwatch icon.

- [ ] **Step 7: Pull-to-refresh and toolbar refresh**

- Pull down on the list → spinner appears, list refreshes.
- Tap the toolbar refresh button → spinner replaces it briefly while refresh runs.

- [ ] **Step 8: Disable the controller and re-enter**

Disconnect the VPN, go to Settings, toggle "Disable Web Controller" on, return to the Dashboard. Confirm:
- The Proxies row is hidden again.
- (The "Open Web UI" link is also hidden — same gate.)

- [ ] **Step 9: Done**

If any of the above failed, file the failure as a bug and stop. Otherwise, the feature is complete.

---

## Self-Review Checklist

- [x] Task 1 covers `MihomoController` (spec §"Architecture → MihomoController").
- [x] Task 2 covers `ProxiesStore` (spec §"Architecture → ProxiesStore").
- [x] Task 3 + Task 4 cover `ProxiesView` (spec §"Architecture → ProxiesView").
- [x] Task 5 covers the dashboard hook (spec §"Architecture → Dashboard hook").
- [x] Task 6 covers the localization (spec §"Localization").
- [x] Task 7 covers the manual smoke (spec §"Testing").
- [x] Auth assumption documented in `MihomoController`'s doc comment (spec §"Auth assumption").
- [x] Empty/error states for VPN-off, controller-off, and connection-refused all rendered (spec §"Error handling").
- [x] Latency pill thresholds match the spec (300 / 800 ms).
- [x] No `TBD` / `TODO` / "similar to Task N" placeholders.
- [x] Every code step has the literal code an engineer would paste.
- [x] Task 7 commands are exact and runnable from the worktree root.

Type-name consistency check across tasks:
- `Proxy`, `ProxyDelayPoint`, `ProxiesResponse`, `DelayResponse`, `MihomoController`, `MihomoControllerError` — defined Task 1, used Tasks 2-4. ✓
- `ProxiesStore.refresh()`, `select(group:name:)`, `testGroup(_:)`, `isSelecting(group:node:)`, `groupTesting`, `selecting`, `groups`, `nodeMap`, `loadError`, `isRefreshing` — defined Task 2, used Task 4. ✓
- `ProxyGroupHeader`, `ProxyRow`, `LatencyPill` — defined Task 4, all referenced from `content` in Task 4. ✓
