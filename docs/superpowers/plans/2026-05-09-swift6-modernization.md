# Swift 6 Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ProxyCat from Swift 5.10 + ObservableObject/Combine/NotificationCenter-tokens/XCTest to Swift 6 strict concurrency + `@Observable` + observation-tracking AsyncStream + Swift Testing, lands as 6 surgical commits on branch `swift6-modernization`.

**Architecture:** Adopt the iOS 17 Observation framework everywhere ProxyCat currently uses ObservableObject. Replace Combine `$published.sink` pipelines with either `didSet` (for one-way persist-on-change) or a small `Observed.values` AsyncStream wrapper around `withObservationTracking` (for cross-store observation). Replace NotificationCenter observer-tokens with `for await note in NotificationCenter.notifications(named:)` Task loops, cancelled in `deinit`. Convert XCTest cases to Swift Testing `@Suite`/`@Test`/`#expect`. Add `throws(MihomoControllerError)` typed-throws to the one client where errors are uniform.

**Tech Stack:** Swift 6.0, iOS 17.0+, XcodeGen, Observation framework, Swift Testing, NetworkExtension, gomobile-bridged Libmihomo (unchanged).

---

## File structure

**New file:**
- `Library/Observed.swift` — `Observed.values(_:)` AsyncStream wrapper around `withObservationTracking`.

**Deleted files (after Phase D):**
- `Library/ObservationBag.swift` — no remaining callers once both Combine sinks (Phase C) and NotificationCenter observer-tokens (Phase D) are gone.

**Modified files (Library/):**
- `project.yml`, `Library/CommandClient.swift`, `Library/ExtensionEnvironment.swift`, `Library/ExtensionProfile.swift`, `Library/Profile.swift` (ProfileStore), `Library/HostSettingsStore.swift`, `Library/RuntimeSettings.swift`, `Library/DailyUsageStore.swift`, `Library/ConnectionsStore.swift`, `Library/ProxiesStore.swift`, `Library/ExtensionCoordinators.swift`, `Library/MihomoController.swift`.

**Modified files (ApplicationLibrary/, Pcat/):**
- All views in `ApplicationLibrary/` (every file currently using `@EnvironmentObject`/`@StateObject`/`@ObservedObject`).
- `ApplicationLibrary/MainView.swift` (the `.environmentObject(...)` chain).
- `ApplicationLibrary/LogView.swift` (LogViewModel, LogStreamData internal classes).
- `ApplicationLibrary/SavedLogsView.swift` (SavedLogsViewModel internal class).

**Modified files (Tests/):**
- All `Tests/LibraryTests/*.swift` (XCTest → Swift Testing in Phase E).

---

## Conventions used by every step

- `make project` regenerates `ProxyCat.xcodeproj/project.pbxproj` from `project.yml`. Do this after editing `project.yml`.
- Build verification: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`. Expect: `** BUILD SUCCEEDED **`.
- Test verification: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test`. Expect: all tests pass.
- Commits use the format: `<short imperative subject>` followed by a 1–2 sentence body. Co-Authored-By footer per repo convention.
- The branch is `swift6-modernization` (already created and contains the design spec commit).

---

## Phase A — Swift 6 toggle

### Task A1: Update `project.yml` to Swift 6 + strict concurrency

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Edit Swift version + strict concurrency**

In `project.yml`, in `settings.base`, change:

```yaml
    SWIFT_VERSION: "5.10"
```

to:

```yaml
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
```

- [ ] **Step 2: Regenerate project**

Run: `make project`
Expected: prints generated files; `git diff ProxyCat.xcodeproj/project.pbxproj` shows `SWIFT_VERSION = 6.0` and `SWIFT_STRICT_CONCURRENCY = complete` in the new base configurations (the previously hand-edited per-target overrides should now match the base — XcodeGen suppresses redundant per-target settings).

- [ ] **Step 3: Build, capture errors**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tee /tmp/swift6-build.log | grep -E "error:|warning:" | head -100`

Expected: small set of strict-concurrency diagnostics. Record them.

- [ ] **Step 4: Resolve diagnostics in-place**

Apply these targeted fixes (in priority order):
1. **Sendable on value types**: any `struct` / `enum` referenced across actor boundaries gets `: Sendable`. Most already are.
2. **`@unchecked Sendable` on already-thread-safe singletons**: leave as-is if already annotated (e.g. `DateParsers` in ConnectionsStore).
3. **`@MainActor` on closures captured into `Task { ... }`**: where Swift 6 demands explicit isolation that was implicit before, write `Task { @MainActor in ... }`.
4. **`nonisolated` on init/deinit reads of immutable state**: occasionally needed for `deinit` on `@MainActor` classes — already done in `ExtensionProfile.deinit`.
5. **Avoid using `RunLoop.main` as a `Scheduler`**: replaced in Phase C anyway (Combine pipelines are gone).

Iterate edits, rebuild, until `xcodebuild ... build` is clean. **Do not** silence warnings with `@preconcurrency import` unless absolutely required by Apple frameworks; document the file:line if you use it.

- [ ] **Step 5: Run tests**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test 2>&1 | tail -30`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add project.yml ProxyCat.xcodeproj/project.pbxproj <any source files modified for Sendable fixes>
git commit -m "$(cat <<'EOF'
Adopt Swift 6 strict concurrency in project.yml

Source-of-truth project.yml now sets SWIFT_VERSION 6.0 and
SWIFT_STRICT_CONCURRENCY complete. Removes the discrepancy where
project.yml said 5.10 but the generated pbxproj had 6.0 hand-edited
in two target configs. Any Sendable / isolation fallout fixed in
the same commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase B — Add `Observed.values` helper

### Task B1: Create `Library/Observed.swift`

**Files:**
- Create: `Library/Observed.swift`

- [ ] **Step 1: Write the helper**

```swift
import Foundation
import Observation

/// Wraps `withObservationTracking` in an `AsyncStream` so observation
/// of `@Observable` properties can be consumed with `for await`. Emits
/// the initial value, then a fresh value every time the read closure's
/// tracked properties change. Stream terminates (and the producer Task
/// cancels) when the consumer breaks out of its loop or its enclosing
/// Task is cancelled.
public enum Observed {
    public static func values<T: Sendable>(
        _ read: @escaping @Sendable @MainActor () -> T
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                while !Task.isCancelled {
                    let value = withObservationTracking({ read() }, onChange: {})
                    continuation.yield(value)
                    await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
                        withObservationTracking({ _ = read() }, onChange: { cc.resume() })
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **` (helper compiles standalone, no callers yet).

- [ ] **Step 3: Commit**

```bash
git add Library/Observed.swift
git commit -m "$(cat <<'EOF'
Add Observed.values AsyncStream wrapper

Wraps withObservationTracking in a re-arming loop exposed as an
AsyncStream so coordinators can replace Combine \`\$x.sink\` with
\`for await x in Observed.values { ... }\`. Used in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase C — `@Observable` migration + view consumer updates + Combine sink elimination

This is the largest commit. It must be atomic because views and stores are tightly coupled (`@StateObject` requires `ObservableObject`; `@State` of an `@Observable` requires `@Observable`). Sub-tasks are individual file edits; verify build only at the end (intermediate states won't compile).

### Migration pattern reference

For every store currently shaped like:

```swift
import Combine

@MainActor
public final class FooStore: ObservableObject {
    @Published public private(set) var bar: T
    @Published public var baz: U
}
```

Convert to:

```swift
import Foundation  // Combine import dropped if no Combine left

@MainActor @Observable
public final class FooStore {
    public private(set) var bar: T
    public var baz: U
}
```

Notes:
- Drop `: ObservableObject` and every `@Published`. Underlying property visibility/access stays identical.
- `@Observable` macro requires `import Observation` only in files that reference the macro symbols — the `@Observable` attribute itself is recognized without it. Add `import Observation` to be safe.
- For singletons with auto-persist (HostSettingsStore, RuntimeSettings), wrap each persisted property's access with `didSet` and gate via a `@ObservationIgnored` `loaded: Bool` flag set true at the end of `init`. This preserves the `dropFirst()` semantics from the prior Combine pipeline.
- For stores that previously had `assign(to: &$x)` pipelines (ConnectionsStore), inline the derived computation into the property setters that drive it.

For views, the swap rules are:
- `@StateObject private var x = X()` → `@State private var x = X()`
- `@ObservedObject var x: X` → `@Bindable var x: X` if bindings used; else `var x: X`
- `@EnvironmentObject private var x: X` → `@Environment(X.self) private var x`
- `.environmentObject(x)` → `.environment(x)`

### Task C1: Migrate `Library/CommandClient.swift`

**Files:**
- Modify: `Library/CommandClient.swift`

- [ ] **Step 1: Apply the swap**

Replace the class header through the `@Published` block:

```swift
import Combine
import Foundation
import Libmihomo

/// Host-app-side counterpart to the gRPC command server running inside
/// the Network Extension. ...
@MainActor
public final class CommandClient: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var traffic: TrafficSnapshot = .zero
    @Published public private(set) var memory: MemoryStats = .zero
```

becomes

```swift
import Foundation
import Libmihomo
import Observation

/// Host-app-side counterpart to the gRPC command server running inside
/// the Network Extension. ...
@MainActor @Observable
public final class CommandClient {
    public private(set) var isConnected: Bool = false
    public private(set) var logs: [LogEntry] = []
    public private(set) var traffic: TrafficSnapshot = .zero
    public private(set) var memory: MemoryStats = .zero
```

The rest of the file (reconnect loop, bridge callbacks, helpers) is unchanged.

### Task C2: Migrate `Library/ExtensionEnvironment.swift`

**Files:**
- Modify: `Library/ExtensionEnvironment.swift`

- [ ] **Step 1: Apply the swap**

```swift
import Combine
import Foundation
import NetworkExtension

@MainActor
public final class ExtensionEnvironment: ObservableObject {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    @Published public var logSearchText: String = ""
    @Published public var reloadError: String?
    @Published public var autoConnectError: String?
```

becomes

```swift
import Foundation
import NetworkExtension
import Observation

@MainActor @Observable
public final class ExtensionEnvironment {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    public var logSearchText: String = ""
    public var reloadError: String?
    public var autoConnectError: String?
```

### Task C3: Migrate `Library/ExtensionProfile.swift`

**Files:**
- Modify: `Library/ExtensionProfile.swift`

- [ ] **Step 1: Apply the swap**

```swift
import Combine
import Foundation
import NetworkExtension

@MainActor
public final class ExtensionProfile: ObservableObject {
    @Published public private(set) var status: NEVPNStatus = .invalid
    @Published public private(set) var manager: NETunnelProviderManager?
```

becomes

```swift
import Foundation
import NetworkExtension
import Observation

@MainActor @Observable
public final class ExtensionProfile {
    public private(set) var status: NEVPNStatus = .invalid
    public private(set) var manager: NETunnelProviderManager?
```

`attachObserver(_:)` and `deinit` keep their NotificationCenter token logic — those are converted to AsyncSequence in Phase D.

### Task C4: Migrate `Library/Profile.swift` (ProfileStore)

**Files:**
- Modify: `Library/Profile.swift`

- [ ] **Step 1: Apply the swap**

Around line 24 in `Library/Profile.swift`:

```swift
@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    public static let activeContentDidChange = Notification.Name("io.proxycat.ProfileStore.activeContentDidChange")

    @Published public private(set) var profiles: [Profile] = []
    @Published public var activeProfileID: UUID?
```

becomes

```swift
@MainActor @Observable
public final class ProfileStore {
    public static let shared = ProfileStore()

    public static let activeContentDidChange = Notification.Name("io.proxycat.ProfileStore.activeContentDidChange")

    public private(set) var profiles: [Profile] = []
    public var activeProfileID: UUID?
```

Add `import Observation` at the top if not already present.

### Task C5: Migrate `Library/HostSettingsStore.swift` (with didSet)

**Files:**
- Modify: `Library/HostSettingsStore.swift`

- [ ] **Step 1: Replace the entire file body**

Replace the complete contents of `Library/HostSettingsStore.swift` with:

```swift
import Foundation
import Observation

/// Single source of truth for host-only preferences (currently the
/// Auto Connect feature and log retention). Persists to
/// `host_settings.json` in the App Group container.
///
/// Mirrors `RuntimeSettings`: load on init, `loaded` flag guards
/// against re-writing what we just loaded, atomic file writes, and a
/// single notification (`hostSettingsDidChange`) posted on every
/// persisted change. Subscribers — currently `ExtensionEnvironment` —
/// react by re-applying the relevant configuration to
/// NETunnelProviderManager.
@MainActor @Observable
public final class HostSettingsStore {
    public static let shared = HostSettingsStore()

    public var autoConnect: AutoConnectConfig {
        didSet { persistAndBroadcast() }
    }
    public var logRetention: LogRetention {
        didSet {
            persistAndBroadcast()
            FilePath.pruneSavedLogs(
                policy: logRetention,
                activePath: LibmihomoBridge.currentLogFilePath()
            )
        }
    }

    /// `didSet` runs only after init returns, so this gate is redundant
    /// for the constructor itself; it's here as a defense-in-depth
    /// guard in case a future refactor introduces a code path that
    /// mutates these properties before the load is complete.
    @ObservationIgnored private var loaded = false

    private init() {
        let stored = JSONFileStore.load(
            HostSettings.self,
            at: FilePath.hostSettingsFilePath,
            default: .defaults
        )
        self.autoConnect = stored.autoConnect
        self.logRetention = stored.logRetention
        self.loaded = true
    }

    private func persistAndBroadcast() {
        guard loaded else { return }
        let snapshot = HostSettings(autoConnect: autoConnect, logRetention: logRetention)
        // Don't broadcast on failure: subscribers would re-apply from
        // in-memory state while the persisted file still holds the old
        // value, silently reverting on the next cold launch.
        guard JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.hostSettingsFilePath,
            category: "HostSettingsStore"
        ) else { return }
        NotificationCenter.default.post(name: AppConfiguration.hostSettingsDidChange, object: self)
    }
}
```

The Combine `Publishers.CombineLatest` + `$logRetention.sink` pipelines are gone; the same effects come from the `didSet` hooks.

### Task C6: Migrate `Library/RuntimeSettings.swift` (three didSet hooks)

**Files:**
- Modify: `Library/RuntimeSettings.swift`

- [ ] **Step 1: Replace the entire file body**

Replace the complete contents with:

```swift
import Foundation
import Observation

/// Single source of truth for runtime preferences shared between the
/// host app and the Network Extension. Persists to `settings.json` in
/// the App Group container; the Go core reads the same file directly
/// on every Start / Reload, so toggling a value here propagates without
/// any option-dictionary plumbing.
///
/// Mutating any property:
///   * Always persists the full snapshot.
///   * Log-level change → posts `runtimeLogLevelDidChange`, routed to
///     a lightweight IPC that calls `log.SetLevel` directly in the
///     extension's mihomo (no `hub.ApplyConfig`).
///   * `disableExternalController` change → posts
///     `runtimeSettingsDidChange`, routed to the heavyweight reload
///     path that re-reads settings.json and rebuilds the config.
@MainActor @Observable
public final class RuntimeSettings {
    public static let shared = RuntimeSettings()

    public var disableExternalController: Bool {
        didSet {
            guard loaded, disableExternalController != oldValue else { return }
            persist()
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeSettingsDidChange,
                object: nil
            )
        }
    }

    public var logLevel: Int {
        didSet {
            guard loaded, logLevel != oldValue else { return }
            persist()
            LibmihomoBridge.setLogLevel(logLevel)
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeLogLevelDidChange,
                object: nil,
                userInfo: ["level": logLevel]
            )
        }
    }

    @ObservationIgnored private var loaded = false

    private init() {
        let stored = JSONFileStore.load(
            Snapshot.self,
            at: FilePath.settingsFilePath,
            default: .defaults
        )
        self.disableExternalController = stored.disableExternalController
        self.logLevel = stored.logLevel
        self.loaded = true
    }

    private func persist() {
        let snapshot = Snapshot(
            disableExternalController: disableExternalController,
            logLevel: logLevel
        )
        JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.settingsFilePath,
            category: "RuntimeSettings"
        )
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(disableExternalController: false, logLevel: 2)
    }
}
```

### Task C7: Migrate `Library/DailyUsageStore.swift`

**Files:**
- Modify: `Library/DailyUsageStore.swift`

- [ ] **Step 1: Apply minimal swap**

This file's only Combine usage is `import Combine` + `@Published`. The persist throttle is already a Task-based delay, so nothing else changes.

```swift
import Combine
import Foundation
import os

@MainActor
public final class DailyUsageStore: ObservableObject {
    public static let shared = DailyUsageStore()
    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "DailyUsageStore")
    @Published public private(set) var entries: [DailyUsageEntry]
```

becomes

```swift
import Foundation
import Observation
import os

@MainActor @Observable
public final class DailyUsageStore {
    public static let shared = DailyUsageStore()
    @ObservationIgnored private static let logger = Logger(subsystem: "io.proxycat.Library", category: "DailyUsageStore")
    public private(set) var entries: [DailyUsageEntry]
```

(All other private fields stay; they're already non-`@Published`.)

### Task C8: Migrate `Library/ConnectionsStore.swift` (with assign-to elimination)

**Files:**
- Modify: `Library/ConnectionsStore.swift`

- [ ] **Step 1: Header swap**

```swift
import Combine
import Foundation
```

becomes

```swift
import Foundation
import Observation
```

Class header:

```swift
@MainActor
public final class ConnectionsStore: ObservableObject {
    @Published public private(set) var connections: [Connection] = []
    @Published public private(set) var uploadTotal: Int64 = 0
    @Published public private(set) var downloadTotal: Int64 = 0
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var loadError: String?
    @Published public var searchQuery: String = ""
    @Published public private(set) var filteredConnections: [Connection] = []
    @Published public private(set) var speedByChain: [String: Int64] = [:]
```

becomes

```swift
@MainActor @Observable
public final class ConnectionsStore {
    public private(set) var connections: [Connection] = []
    public private(set) var uploadTotal: Int64 = 0
    public private(set) var downloadTotal: Int64 = 0
    public private(set) var isStreaming: Bool = false
    public private(set) var loadError: String?
    public var searchQuery: String = "" {
        didSet { scheduleFilterDebounce() }
    }
    public private(set) var filteredConnections: [Connection] = []
    public private(set) var speedByChain: [String: Int64] = [:]
```

- [ ] **Step 2: Replace the Combine `assign(to:)` pipeline in `init`**

Delete the `init` body's Combine block (the `$searchQuery.debounce(...).combineLatest($connections).map(...).assign(to: &$filteredConnections)` chain). Replace with:

```swift
public init(
    baseURL: URL = MihomoController.defaultBaseURL,
    session: URLSession = .shared
) {
    self.baseURL = baseURL
    self.session = session
}
```

- [ ] **Step 3: Add filter scheduling helpers**

Add these private members near the other `private var` declarations (after `chainSpeedsBuf`):

```swift
@ObservationIgnored private var filterDebounceTask: Task<Void, Never>?

private func scheduleFilterDebounce() {
    filterDebounceTask?.cancel()
    filterDebounceTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let self else { return }
        self.recomputeFilter()
    }
}

private func recomputeFilter() {
    filteredConnections = Self.applyFilter(query: searchQuery, to: connections)
}
```

- [ ] **Step 4: Refilter on every WS frame**

In `apply(_:)`, after the existing `connections = next` line (around line 366), add:

```swift
recomputeFilter()
```

This replaces the `combineLatest($connections)` arm of the old pipeline.

- [ ] **Step 5: Cancel debounce in `stop()` and `deinit`**

In `stop()`, after the existing cancellations, add:

```swift
filterDebounceTask?.cancel()
filterDebounceTask = nil
filteredConnections = []
```

In `deinit`, add:

```swift
filterDebounceTask?.cancel()
```

### Task C9: Migrate `Library/ProxiesStore.swift`

**Files:**
- Modify: `Library/ProxiesStore.swift`

- [ ] **Step 1: Apply the swap**

```swift
import Combine
import Foundation

@MainActor
public final class ProxiesStore: ObservableObject {
    @Published public private(set) var groups: [Proxy] = []
    @Published public private(set) var nodeMap: [String: Proxy] = [:]
    @Published public private(set) var loadError: String?
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var groupTesting: Set<String> = []
    @Published public private(set) var selecting: Set<String> = []
    @Published public private(set) var collapsed: Set<String> = []
```

becomes

```swift
import Foundation
import Observation

@MainActor @Observable
public final class ProxiesStore {
    public private(set) var groups: [Proxy] = []
    public private(set) var nodeMap: [String: Proxy] = [:]
    public private(set) var loadError: String?
    public private(set) var isRefreshing: Bool = false
    public private(set) var groupTesting: Set<String> = []
    public private(set) var selecting: Set<String> = []
    public private(set) var collapsed: Set<String> = []
```

### Task C10: Migrate `Library/ExtensionCoordinators.swift` (Combine sinks → Observed.values)

**Files:**
- Modify: `Library/ExtensionCoordinators.swift`

- [ ] **Step 1: Header swap**

```swift
import Combine
import Foundation
import NetworkExtension
```

becomes

```swift
import Foundation
import NetworkExtension
```

(Phase D removes the remaining NotificationCenter token machinery; for now keep `bag = ObservationBag()` lines on coordinators that still use it.)

- [ ] **Step 2: Replace `VPNLifecycleCoordinator.start()`**

Replace:

```swift
public func start() {
    let cancellable = profile.$status
        .receive(on: RunLoop.main)
        .sink { [weak self] status in
            self?.apply(status)
        }
    bag.store(cancellable)
    apply(profile.status)
}
```

with:

```swift
@ObservationIgnored private var observationTask: Task<Void, Never>?

public func start() {
    apply(profile.status)
    observationTask?.cancel()
    observationTask = Task { @MainActor [weak self] in
        guard let self else { return }
        for await status in Observed.values({ self.profile.status }).dropFirst() {
            self.apply(status)
        }
    }
}

deinit {
    observationTask?.cancel()
}
```

`Observed.values(...).dropFirst()` matches the prior `apply(profile.status); profile.$status.sink { apply }` pattern exactly: emit-current-then-stream becomes drop-the-replay-and-stream-changes (we already called `apply(profile.status)` synchronously above).

The `bag` field on this coordinator is no longer used; remove the `private let bag = ObservationBag()` line.

- [ ] **Step 3: Replace `TrafficCoordinator.start()`**

Replace:

```swift
public func start() {
    let cancellable = commandClient.$traffic
        .dropFirst()
        .removeDuplicates()
        .sink { [usageStore] snapshot in
            Task { @MainActor in usageStore.record(snapshot: snapshot) }
        }
    bag.store(cancellable)
}
```

with:

```swift
@ObservationIgnored private var observationTask: Task<Void, Never>?

public func start() {
    observationTask?.cancel()
    let usageStore = self.usageStore
    observationTask = Task { @MainActor [weak self] in
        guard let self else { return }
        var last: TrafficSnapshot?
        for await snapshot in Observed.values({ self.commandClient.traffic }).dropFirst() {
            if snapshot == last { continue }
            last = snapshot
            usageStore.record(snapshot: snapshot)
        }
    }
}

deinit {
    observationTask?.cancel()
}
```

The manual `last`/dedupe replicates `removeDuplicates()`. Remove this coordinator's `bag` field too.

- [ ] **Step 4: Leave `SettingsChangeCoordinator` and `AutoConnectCoordinator` untouched in this commit**

They still use `bag.add(NotificationCenter…)` — Phase D rewrites them.

### Task C11: View consumer migration sweep

**Files:**
- Modify: `ApplicationLibrary/MainView.swift`
- Modify: `ApplicationLibrary/DashboardView.swift`
- Modify: `ApplicationLibrary/SettingsView.swift`
- Modify: `ApplicationLibrary/StatisticsView.swift`
- Modify: `ApplicationLibrary/AutoConnectSettingsView.swift`
- Modify: `ApplicationLibrary/ProfileEditorView.swift`
- Modify: `ApplicationLibrary/ProfileListView.swift`
- Modify: `ApplicationLibrary/ProfileDownloadView.swift`
- Modify: `ApplicationLibrary/ProxiesView.swift`
- Modify: `ApplicationLibrary/ConnectionsView.swift`
- Modify: `ApplicationLibrary/LogView.swift`
- Modify: `ApplicationLibrary/SavedLogsView.swift`

- [ ] **Step 1: `MainView.swift`**

In `ApplicationLibrary/MainView.swift`, replace:

```swift
@StateObject private var environment = ExtensionEnvironment()
```

with:

```swift
@State private var environment = ExtensionEnvironment()
```

Replace the modifier chain:

```swift
.environmentObject(environment)
.environmentObject(environment.profile)
.environmentObject(environment.commandClient)
.environmentObject(ProfileStore.shared)
// the comment about same observable identity stays correct
.environmentObject(RuntimeSettings.shared)
.environmentObject(HostSettingsStore.shared)
.environmentObject(DailyUsageStore.shared)
```

with:

```swift
.environment(environment)
.environment(environment.profile)
.environment(environment.commandClient)
.environment(ProfileStore.shared)
.environment(RuntimeSettings.shared)
.environment(HostSettingsStore.shared)
.environment(DailyUsageStore.shared)
```

The "same observable identity" comment now reads naturally — `@Observable` types are reference types and `.environment(_:)` propagates the same instance to descendants.

- [ ] **Step 2: `DashboardView.swift`**

Replace:

```swift
@EnvironmentObject private var environment: ExtensionEnvironment
@EnvironmentObject private var profile: ExtensionProfile
@EnvironmentObject private var commandClient: CommandClient
@EnvironmentObject private var profileStore: ProfileStore
@EnvironmentObject private var settings: RuntimeSettings
```

with:

```swift
@Environment(ExtensionEnvironment.self) private var environment
@Environment(ExtensionProfile.self) private var profile
@Environment(CommandClient.self) private var commandClient
@Environment(ProfileStore.self) private var profileStore
@Environment(RuntimeSettings.self) private var settings
```

If the body uses `$settings.disableExternalController` or any other binding, add `@Bindable var settings = settings` (or whichever is bound) inside the body before the binding is consumed. Use of `$environment.reloadError` inside `.alert(item: ...)` style calls similarly needs `@Bindable var environment = environment`.

- [ ] **Step 3: `SettingsView.swift`**

Replace:

```swift
@EnvironmentObject private var settings: RuntimeSettings
@EnvironmentObject private var hostSettings: HostSettingsStore
```

with:

```swift
@Environment(RuntimeSettings.self) private var settings
@Environment(HostSettingsStore.self) private var hostSettings
```

Where Toggles bind to `settings.logLevel`, `settings.disableExternalController`, or `hostSettings.logRetention`, declare `@Bindable var settings = settings` and `@Bindable var hostSettings = hostSettings` at the top of the body so `$settings.…` keeps working.

- [ ] **Step 4: `StatisticsView.swift`**

Replace:

```swift
@EnvironmentObject private var dailyUsage: DailyUsageStore
```

with:

```swift
@Environment(DailyUsageStore.self) private var dailyUsage
```

- [ ] **Step 5: `AutoConnectSettingsView.swift`**

Replace:

```swift
@EnvironmentObject private var store: HostSettingsStore
@EnvironmentObject private var profileStore: ProfileStore
@EnvironmentObject private var environment: ExtensionEnvironment
```

with:

```swift
@Environment(HostSettingsStore.self) private var store
@Environment(ProfileStore.self) private var profileStore
@Environment(ExtensionEnvironment.self) private var environment
```

Add `@Bindable var store = store` and `@Bindable var environment = environment` inside the body where `$store.autoConnect.*` or `$environment.autoConnectError` bindings are used.

- [ ] **Step 6: `ProfileEditorView.swift`**

Replace:

```swift
@EnvironmentObject private var store: ProfileStore
```

with:

```swift
@Environment(ProfileStore.self) private var store
```

- [ ] **Step 7: `ProfileListView.swift`**

Replace:

```swift
@EnvironmentObject private var profileStore: ProfileStore
```

with:

```swift
@Environment(ProfileStore.self) private var profileStore
```

If the view passes a binding to `profileStore.activeProfileID` (e.g. via a `Picker`'s `selection: $profileStore.activeProfileID`), declare `@Bindable var profileStore = profileStore` inside the body first.

- [ ] **Step 8: `ProfileDownloadView.swift`**

Replace:

```swift
@EnvironmentObject private var store: ProfileStore
```

with:

```swift
@Environment(ProfileStore.self) private var store
```

- [ ] **Step 9: `ProxiesView.swift`**

Replace:

```swift
@EnvironmentObject private var profile: ExtensionProfile
@EnvironmentObject private var settings: RuntimeSettings
@StateObject private var store = ProxiesStore()
```

with:

```swift
@Environment(ExtensionProfile.self) private var profile
@Environment(RuntimeSettings.self) private var settings
@State private var store = ProxiesStore()
```

- [ ] **Step 10: `ConnectionsView.swift`**

Replace:

```swift
@EnvironmentObject private var profile: ExtensionProfile
@EnvironmentObject private var settings: RuntimeSettings
@StateObject private var store = ConnectionsStore()
```

with:

```swift
@Environment(ExtensionProfile.self) private var profile
@Environment(RuntimeSettings.self) private var settings
@State private var store = ConnectionsStore()
```

If the SearchableModifier binds to `store.searchQuery` via `$store.searchQuery`, declare `@Bindable var store = store` inside the body first.

- [ ] **Step 11: `LogView.swift`**

Top of the file (around line 30):

```swift
@EnvironmentObject private var environment: ExtensionEnvironment
@StateObject private var model: LogViewModel
```

becomes

```swift
@Environment(ExtensionEnvironment.self) private var environment
@State private var model: LogViewModel
```

Around line 133:

```swift
@ObservedObject var stream: LogStreamData
```

becomes

```swift
@Bindable var stream: LogStreamData
```

(or just `var stream: LogStreamData` if no bindings used — check the body usage).

The two internal classes (around lines 227 and 232):

```swift
final class LogStreamData: ObservableObject {
    @Published var visible: [LogEntry] = []
    ...
}

final class LogViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedLevel: LogLevel
    @Published var isPaused: Bool = false
    @Published var isConnected: Bool = false
    @Published var justCopied: Bool = false
    @Published var lastCopyCount: Int = 0
    ...
}
```

become:

```swift
@MainActor @Observable
final class LogStreamData {
    var visible: [LogEntry] = []
    ...
}

@MainActor @Observable
final class LogViewModel {
    var searchText: String = ""
    var selectedLevel: LogLevel
    var isPaused: Bool = false
    var isConnected: Bool = false
    var justCopied: Bool = false
    var lastCopyCount: Int = 0
    ...
}
```

If `LogView` passes bindings to `model.searchText` (via `.searchable(text: $model.searchText)`), declare `@Bindable var model = model` at the top of the body.

- [ ] **Step 12: `SavedLogsView.swift`**

Replace:

```swift
@StateObject private var model = SavedLogsViewModel()
```

with:

```swift
@State private var model = SavedLogsViewModel()
```

The `SavedLogsViewModel` class itself (around line 205):

```swift
final class SavedLogsViewModel: ObservableObject {
    @Published var entries: [SavedLogEntry] = []
    @Published var confirmDeleteAll: Bool = false
    ...
}
```

becomes:

```swift
@MainActor @Observable
final class SavedLogsViewModel {
    var entries: [SavedLogEntry] = []
    var confirmDeleteAll: Bool = false
    ...
}
```

If body uses `$model.entries` etc., declare `@Bindable var model = model` inside the body.

### Task C12: Build, fix, test, commit

- [ ] **Step 1: Build**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:" | head -50`

Expected initial output: a flurry of errors. Common categories and fixes:

- *Cannot find type 'Bindable' in scope.* → Add `import SwiftUI` at top of the view file (most already have it; only one or two view files might be using a separate model file).
- *Property '$x' is not declared.* → Add `@Bindable var x = x` inside the body, before the `$x.…` reference.
- *Initializer 'init(_:)' requires that 'X' conform to 'ObservableObject'.* → A `.environmentObject(x)` was missed; change to `.environment(x)`.
- *'@Observable' classes can't be used with @StateObject.* → A `@StateObject` was missed; change to `@State`.
- *Cannot use mutating member on immutable value: 'self' is immutable.* → A view body wrote to a `@Bindable`-derived binding from a non-mutating context. Re-declare the property with `@Bindable` at the variable level rather than in the body.

Iterate edits → rebuild until green.

- [ ] **Step 2: Run tests**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test 2>&1 | tail -30`
Expected: all pass. If `DailyUsageTests` regressed, double-check the `entries` property still reads + writes the same way.

- [ ] **Step 3: Commit**

```bash
git add Library/CommandClient.swift Library/ExtensionEnvironment.swift Library/ExtensionProfile.swift \
  Library/Profile.swift Library/HostSettingsStore.swift Library/RuntimeSettings.swift \
  Library/DailyUsageStore.swift Library/ConnectionsStore.swift Library/ProxiesStore.swift \
  Library/ExtensionCoordinators.swift \
  ApplicationLibrary/
git commit -m "$(cat <<'EOF'
Migrate stores and views to @Observable

Drops ObservableObject + @Published from every store/view-model in
Library/ and ApplicationLibrary/. Views move from @StateObject /
@ObservedObject / @EnvironmentObject to @State / @Bindable /
@Environment(_:). HostSettingsStore and RuntimeSettings now persist via
didSet hooks instead of CombineLatest sinks. ConnectionsStore replaces
its assign(to:) filter pipeline with a debounced Task. VPNLifecycle and
TrafficCoordinator switch from \`\$x.sink\` to Observed.values.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase D — NotificationCenter → AsyncSequence (delete ObservationBag)

### Task D1: Convert `SettingsChangeCoordinator`

**Files:**
- Modify: `Library/ExtensionCoordinators.swift`

- [ ] **Step 1: Replace the coordinator body**

Replace the existing class (the one with three `bag.add(...)` calls) with:

```swift
@MainActor
public final class SettingsChangeCoordinator {
    public var onError: ((String) -> Void)?

    private let profile: ExtensionProfile
    private var tasks: [Task<Void, Never>] = []

    public init(profile: ExtensionProfile) {
        self.profile = profile
    }

    public func start() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        let center = NotificationCenter.default

        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: ProfileStore.activeContentDidChange) {
                await self?.reloadIfConnected()
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: AppConfiguration.runtimeSettingsDidChange) {
                await self?.reloadIfConnected()
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await note in center.notifications(named: AppConfiguration.runtimeLogLevelDidChange) {
                guard let level = note.userInfo?["level"] as? Int else { continue }
                await self?.applyLogLevelIfConnected(level)
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    private func reloadIfConnected() async {
        guard profile.isConnected else { return }
        do {
            try await profile.reload()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func applyLogLevelIfConnected(_ level: Int) async {
        guard profile.isConnected else { return }
        do {
            try await profile.setLogLevel(level)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}
```

### Task D2: Convert `AutoConnectCoordinator`

**Files:**
- Modify: `Library/ExtensionCoordinators.swift`

- [ ] **Step 1: Replace the coordinator body**

Replace the existing class with:

```swift
@MainActor
public final class AutoConnectCoordinator {
    public var onError: ((String) -> Void)?

    private let profile: ExtensionProfile
    private let store: HostSettingsStore
    private var observationTask: Task<Void, Never>?

    public init(profile: ExtensionProfile, store: HostSettingsStore) {
        self.profile = profile
        self.store = store
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AppConfiguration.hostSettingsDidChange) {
                await self?.applyFromStore()
            }
        }
    }

    public func applyFromStore() async {
        let config = store.autoConnect
        do {
            try await profile.applyAutoConnect(config)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
```

### Task D3: Convert `ExtensionProfile.attachObserver`

**Files:**
- Modify: `Library/ExtensionProfile.swift`

- [ ] **Step 1: Replace the observer machinery**

Replace:

```swift
private var statusObserver: NSObjectProtocol?

private func attachObserver(_ manager: NETunnelProviderManager) {
    if let token = statusObserver {
        NotificationCenter.default.removeObserver(token)
    }
    statusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: manager.connection,
        queue: .main
    ) { [weak self] note in
        guard let conn = note.object as? NEVPNConnection else { return }
        let status = conn.status
        Task { @MainActor in
            self?.status = status
        }
    }
}

deinit {
    if let token = statusObserver {
        NotificationCenter.default.removeObserver(token)
    }
}
```

with:

```swift
@ObservationIgnored private var statusObservationTask: Task<Void, Never>?

private func attachObserver(_ manager: NETunnelProviderManager) {
    statusObservationTask?.cancel()
    let connection = manager.connection
    statusObservationTask = Task { @MainActor [weak self] in
        for await note in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection) {
            guard let conn = note.object as? NEVPNConnection else { continue }
            self?.status = conn.status
        }
    }
}

deinit {
    statusObservationTask?.cancel()
}
```

### Task D4: Delete `Library/ObservationBag.swift`

**Files:**
- Delete: `Library/ObservationBag.swift`

- [ ] **Step 1: Confirm zero callers**

Run: `grep -rn "ObservationBag\|\\.bag\\.add\\|bag\\.store" Library/ ApplicationLibrary/ Pcat/ PcatExtension/`
Expected: no matches.

- [ ] **Step 2: Delete the file**

Run: `git rm Library/ObservationBag.swift`

- [ ] **Step 3: Regenerate project**

Run: `make project`

### Task D5: Build, test, commit

- [ ] **Step 1: Build**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run tests**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test 2>&1 | tail -10`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Library/ExtensionCoordinators.swift Library/ExtensionProfile.swift ProxyCat.xcodeproj/project.pbxproj
git rm Library/ObservationBag.swift  # already staged via git rm
git commit -m "$(cat <<'EOF'
Replace NotificationCenter observer tokens with AsyncSequence

Coordinators (SettingsChangeCoordinator, AutoConnectCoordinator) and
ExtensionProfile now drive their notification subscriptions with
NotificationCenter.notifications(named:) consumed in for-await Task
loops. Tasks cancel in deinit, replacing the manual removeObserver
bookkeeping that ObservationBag was doing. ObservationBag has no
remaining callers and is deleted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase E — XCTest → Swift Testing

### Conversion mapping reference

| XCTest | Swift Testing |
|---|---|
| `import XCTest` | `import Testing` |
| `final class FooTests: XCTestCase` | `@Suite struct FooTests` |
| `func test_x() throws { ... }` | `@Test func x() throws { ... }` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertEqual(a, b, accuracy: e)` | `#expect(abs(a - b) < e)` |
| `XCTAssertNotEqual(a, b)` | `#expect(a != b)` |
| `XCTAssertNil(a)` | `#expect(a == nil)` |
| `XCTAssertNotNil(a)` | `#expect(a != nil)` |
| `XCTAssertTrue(a)` | `#expect(a)` |
| `XCTAssertFalse(a)` | `#expect(!a)` |
| `XCTAssertGreaterThan(a, b)` | `#expect(a > b)` |
| `XCTAssertLessThan(a, b)` | `#expect(a < b)` |
| `XCTAssertThrowsError(try f())` | `#expect(throws: (any Error).self) { try f() }` |
| `XCTAssertThrowsError(try f()) { e in #expect(e is FooError) }` | `#expect(throws: FooError.self) { try f() }` |
| `XCTAssertNoThrow(try f())` | `#expect(throws: Never.self) { try f() }` |
| `XCTFail("msg")` | `Issue.record("msg")` |
| `setUp()` / `tearDown()` | `init()` / `deinit` (or `init() async throws`) |

A `@Suite struct` is the natural unit; switch to `final class` only if `deinit` async cleanup is required.

### Task E1: Convert `Tests/LibraryTests/AutoConnectTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/AutoConnectTests.swift`

- [ ] **Step 1: Read existing file**

Run: `cat Tests/LibraryTests/AutoConnectTests.swift`
Identify each `func test_…`, each XCTAssert call, and any setUp/tearDown.

- [ ] **Step 2: Rewrite using the mapping table**

Replace the file. Pattern (apply per-test):

```swift
import XCTest
@testable import Library

final class AutoConnectTests: XCTestCase {
    func testFoo() {
        let c = AutoConnectConfig(...)
        XCTAssertTrue(c.enabled)
    }
}
```

becomes

```swift
import Testing
@testable import Library

@Suite struct AutoConnectTests {
    @Test func foo() {
        let c = AutoConnectConfig(...)
        #expect(c.enabled)
    }
}
```

Walk through each method in the source, applying the table. Keep test names readable (drop the `test` prefix; use `func ssidRuleTrumpsCellular()` rather than `func test_ssidRuleTrumpsCellular()`).

### Task E2: Convert `Tests/LibraryTests/MemoryStatsTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/MemoryStatsTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

### Task E3: Convert `Tests/LibraryTests/DailyUsageTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/DailyUsageTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

If the suite uses `@MainActor`-bound `DailyUsageStore`, mark either the suite (`@Suite @MainActor struct …`) or each `@Test func` `@MainActor`. Match what XCTest used.

### Task E4: Convert `Tests/LibraryTests/ProfileStoreTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/ProfileStoreTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

`ProfileStore` is `@MainActor`; mark suite or tests `@MainActor` accordingly.

### Task E5: Convert `Tests/LibraryTests/MihomoControllerTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/MihomoControllerTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

If the suite uses URLSession mocking (URLProtocol subclass) registered via setUp/tearDown, move registration into `init()` and unregistration into `deinit` of a `final class` suite (Swift Testing supports class suites).

### Task E6: Convert `Tests/LibraryTests/JSONFileStoreTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/JSONFileStoreTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

### Task E7: Convert `Tests/LibraryTests/ExponentialBackoffTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/ExponentialBackoffTests.swift`

- [ ] **Step 1: Apply the per-test conversion**

Note that this file has async tests — keep them `async`. `XCTAssertGreaterThan(total, 1, "msg")` becomes `#expect(total > 1, "msg")`.

### Task E8: Convert `Tests/LibraryTests/LogEntryTests.swift`

**Files:**
- Modify: `Tests/LibraryTests/LogEntryTests.swift`

- [ ] **Step 1: Apply the same per-test conversion as E1.**

### Task E9: Build, test, commit

- [ ] **Step 1: Run tests**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test 2>&1 | tail -30`

Expected: Swift Testing reports the suite results in its own format. If a test fails, fix the per-conversion (often a missing `@MainActor` annotation on a suite that was implicitly main-thread under XCTest).

- [ ] **Step 2: Verify count**

The Swift Testing run summary should show roughly the same number of tests as the prior XCTest run (count function-test methods in pre-conversion files; should match).

- [ ] **Step 3: Commit**

```bash
git add Tests/LibraryTests/
git commit -m "$(cat <<'EOF'
Migrate LibraryTests to Swift Testing

Each XCTestCase becomes a @Suite struct; each test_ method becomes a
@Test func; XCTAssert family swaps to #expect. setUp/tearDown lifted
into init/deinit. URLProtocol-mocking suites become class-based suites
to keep deinit cleanup. No behavioral change to the test bodies.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase F — Typed throws on `MihomoController`

### Task F1: Annotate `MihomoController` methods

**Files:**
- Modify: `Library/MihomoController.swift`

- [ ] **Step 1: Apply typed-throws to the public methods**

Replace:

```swift
public func proxies() async throws -> [String: Proxy] {
    let req = makeRequest(path: "proxies", timeout: 5)
    let data = try await perform(req)
    do {
        return try decoder.decode(ProxiesResponse.self, from: data).proxies
    } catch {
        throw MihomoControllerError.decoding(error)
    }
}

public func select(group: String, name: String) async throws {
    var req = makeRequest(path: "proxies/\(Self.percentEncodeSegment(group))", timeout: 5)
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
    _ = try await perform(req)
}

public func groupDelay(
    name: String,
    url: String? = nil,
    timeoutMs: Int? = nil,
    expectedStatus: String? = nil
) async throws -> [String: Int] {
    ...
}
```

with:

```swift
public func proxies() async throws(MihomoControllerError) -> [String: Proxy] {
    let req = makeRequest(path: "proxies", timeout: 5)
    let data = try await perform(req)
    do {
        return try decoder.decode(ProxiesResponse.self, from: data).proxies
    } catch {
        throw MihomoControllerError.decoding(error)
    }
}

public func select(group: String, name: String) async throws(MihomoControllerError) {
    var req = makeRequest(path: "proxies/\(Self.percentEncodeSegment(group))", timeout: 5)
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
    } catch {
        throw MihomoControllerError.decoding(error)
    }
    _ = try await perform(req)
}

public func groupDelay(
    name: String,
    url: String? = nil,
    timeoutMs: Int? = nil,
    expectedStatus: String? = nil
) async throws(MihomoControllerError) -> [String: Int] {
    ...
}
```

The `select(...)` body required wrapping the previously-untyped `JSONSerialization.data` throw in a `MihomoControllerError.decoding`.

- [ ] **Step 2: Tighten `perform(_:)` signature**

```swift
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

becomes:

```swift
private func perform(_ request: URLRequest) async throws(MihomoControllerError) -> Data {
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await session.data(for: request)
    } catch let err as URLError {
        throw MihomoControllerError.transport(err)
    } catch {
        throw MihomoControllerError.invalidResponse
    }
    guard let http = response as? HTTPURLResponse else {
        throw MihomoControllerError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw MihomoControllerError.requestFailed(status: http.statusCode, body: body)
    }
    return data
}
```

The catch-rethrow chain collapses because `perform` now claims it only throws `MihomoControllerError`.

- [ ] **Step 3: Build**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`. Callers that already wrote `do { try await controller.…() } catch { … }` work unchanged because Swift's typed throws is covariant — calling `try` against `throws(MihomoControllerError)` is the same as `try` against `throws`.

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project ProxyCat.xcodeproj -scheme LibraryTests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test 2>&1 | tail -10`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Library/MihomoController.swift
git commit -m "$(cat <<'EOF'
Adopt typed throws on MihomoController

proxies/select/groupDelay/perform all already throw exactly
MihomoControllerError today; promote the implicit invariant to a
\`throws(MihomoControllerError)\` annotation. Callers compile
unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] **Step 1: No Combine, no @Published, no ObservableObject in Library/ApplicationLibrary**

Run: `git grep -nE "ObservableObject|@Published|import Combine" Library/ ApplicationLibrary/ Pcat/ PcatExtension/`
Expected: no matches.

- [ ] **Step 2: No XCTest in Tests/LibraryTests**

Run: `git grep -n "import XCTest\|XCTAssert\|XCTestCase" Tests/`
Expected: no matches.

- [ ] **Step 3: Commit log review**

Run: `git log --oneline main..HEAD`
Expected: 7 commits (1 spec + 6 implementation), short subjects, coherent narrative.

- [ ] **Step 4: README spot-check**

Run: `git grep -nE "Swift|swift-tools-version" README.md`
If README mentions `Swift 5.x` or similar, update it in a follow-up commit (or fold into the typed-throws commit if minor).

- [ ] **Step 5: Manual smoke (optional but recommended)**

Boot a simulator. Build + run the `Pcat` scheme. Verify:
- VPN connect → traffic graphs animate, log stream populates.
- Edit profile YAML → reload triggers, dashboard reflects new state.
- Toggle "Disable external controller" in Settings → controller becomes unreachable; toggle back → recovers.
- Add an SSID auto-connect rule → on-demand rules update without disconnecting.

If any of these regress, bisect via `git bisect run xcodebuild test …` against the per-phase commits.

---

## Branch + PR

- [ ] **Step 1: Push the branch**

Run: `git push -u origin swift6-modernization`

- [ ] **Step 2: Open PR (if user requests)**

Wait for explicit user instruction — `gh pr create` is only run when asked.
