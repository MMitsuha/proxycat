# Swift 6 modernization

Migrate ProxyCat from Swift 5.10 (with hand-edited per-target Swift 6 toggles) to a coherent Swift 6 / strict-concurrency build, and replace pre-iOS-17 idioms (`ObservableObject` / `@Published` / Combine sinks / NotificationCenter observer tokens / XCTest) with their modern counterparts. Lands as a series of small commits on a new branch.

## Goals

- Single source of truth for Swift version: `project.yml` says `6.0` with `SWIFT_STRICT_CONCURRENCY: complete`. The generated `pbxproj` matches without manual edits.
- All eleven `ObservableObject` types in `Library/` and `ApplicationLibrary/` use the iOS 17 `@Observable` macro.
- Combine is no longer imported by ProxyCat code (the `import Combine` set drops to zero).
- Coordinators that used to track Notification observer tokens via `ObservationBag` now run a `Task` per stream and cancel in `deinit`.
- `Tests/LibraryTests/` runs under Swift Testing.
- `MihomoController` (and any other API with a uniform error type) uses typed throws.
- No public-API breakage that callers outside the project would care about — but internal frameworks (`Library`, `ApplicationLibrary`) freely change. The host App / Network Extension targets compile against the new shape.

## Non-goals

- Re-architecting the Go ↔ Swift bridge or gRPC plumbing. The `Libmihomo` interface is unchanged.
- Rewriting the OOM guard, ExponentialBackoff, AsyncOneShot, ManagedResume, MemoryMonitor — these are correct and have no stdlib equivalents worth swapping in.
- Touching `JSONFileStore`'s API beyond what typed-throws and Sendable hygiene require.
- Migrating from XcodeGen, the `make` build, or the gomobile toolchain.

## Inventory

### `ObservableObject` types to migrate (in `Library/`)

| Type | Properties | Notes |
|---|---|---|
| `CommandClient` | `isConnected`, `logs`, `traffic`, `memory` | gomobile bridge calls into it from Go threads; already `@MainActor` |
| `ExtensionEnvironment` | `logSearchText`, `reloadError`, `autoConnectError` | Composes four coordinators |
| `ExtensionProfile` | `status`, `manager` | Owns NEVPN observer |
| `ProfileStore` | `profiles`, `activeProfileID` | Singleton; cross-process notifications |
| `HostSettingsStore` | `autoConnect`, `logRetention` | Singleton; auto-persist on change |
| `RuntimeSettings` | `disableExternalController`, `logLevel` | Singleton; auto-persist on change |
| `DailyUsageStore` | `entries` | Singleton; throttled persist |
| `ConnectionsStore` | `connections`, `upload/downloadTotal`, `isStreaming`, `loadError`, `searchQuery`, `filteredConnections`, `speedByChain` | Per-view state |
| `ProxiesStore` | `groups`, `nodeMap`, `loadError`, `isRefreshing`, `groupTesting`, `selecting`, `collapsed` | Per-view state |
| `LogViewModel` (in `LogView.swift`) | `searchText`, `selectedLevel`, `isPaused`, `isConnected`, `justCopied`, `lastCopyCount` | Per-view state |
| `LogStreamData` (in `LogView.swift`) | `visible` | Per-view state, separate model so log-frame appends don't invalidate the toolbar |
| `SavedLogsViewModel` (in `SavedLogsView.swift`) | `entries`, `confirmDeleteAll` | Per-view state |

### Combine pipelines to replace

| File | Pattern | Replacement |
|---|---|---|
| `HostSettingsStore` | `Publishers.CombineLatest($a, $b).dropFirst().sink { persist }` | `didSet` on each property → `persist()`. The `dropFirst` (skip-init) effect comes from setting properties before installing didSet via a small init flag. |
| `HostSettingsStore` | `$logRetention.dropFirst().sink { prune }` | Same — `didSet` on `logRetention`. |
| `RuntimeSettings` | (analogous CombineLatest sink) | Same. |
| `DailyUsageStore` | (Combine throttle for persist) | `Task` with `Task.sleep(for: 5s)` debouncer. |
| `VPNLifecycleCoordinator` | `profile.$status.sink { apply }` | `withObservationTracking` re-arming loop in a `Task`. |
| `TrafficCoordinator` | `commandClient.$traffic.dropFirst().removeDuplicates().sink { record }` | Same — observation-tracking loop with last-value dedupe. |

### NotificationCenter observers to convert to AsyncSequence

| File | Notification | Owner |
|---|---|---|
| `SettingsChangeCoordinator` | `ProfileStore.activeContentDidChange` | `Task` cancelled in `deinit` |
| `SettingsChangeCoordinator` | `AppConfiguration.runtimeSettingsDidChange` | Same |
| `SettingsChangeCoordinator` | `AppConfiguration.runtimeLogLevelDidChange` | Same |
| `AutoConnectCoordinator` | `AppConfiguration.hostSettingsDidChange` | Same |
| `ExtensionProfile.attachObserver` | `.NEVPNStatusDidChange` | Same |

After all five conversions, `Library/ObservationBag.swift` has no callers and is deleted.

### Test files (XCTest → Swift Testing)

`Tests/LibraryTests/`: `AutoConnectTests.swift`, `MemoryStatsTests.swift`, `DailyUsageTests.swift`, `ProfileStoreTests.swift`, `MihomoControllerTests.swift`, `JSONFileStoreTests.swift`, `ExponentialBackoffTests.swift`, `LogEntryTests.swift`.

### Typed-throws candidates

- `MihomoController.proxies / select / groupDelay`: all throw exactly `MihomoControllerError` today → annotate `throws(MihomoControllerError)`.
- `JSONFileStore`: heterogeneous (Foundation errors + decoding errors) → leave untyped.
- `ExtensionProfile.reload / setLogLevel / start / load`: heterogeneous (NEVPN errors + custom) → leave untyped.
- `ProfileStore.*`: heterogeneous → leave untyped.

## Commit sequence

Each commit must build clean (`make project && xcodebuild build -scheme Pcat`) and tests must pass (`xcodebuild test -scheme Library`) before moving to the next.

### Commit 1 — `project.yml`: Swift 6 + strict concurrency

- `SWIFT_VERSION: "5.10"` → `"6.0"`
- Add `SWIFT_STRICT_CONCURRENCY: complete` to base settings
- Run `make project` — confirms the generated `pbxproj` no longer needs hand-edits
- Fix any new compiler errors. Expected hot spots:
  - `MemoryMonitor` shared-state singleton — may need `@MainActor` or explicit isolation
  - `DateParsers` in `ConnectionsStore` (already `@unchecked Sendable`) — verify
  - `Notification.userInfo` capture in coordinators — already wrapped in `Task { @MainActor }`, should be fine
  - `URLSession.shared` captures — `Sendable` already
- README: bump `## 环境要求` if it mentions Swift version (it doesn't appear to currently — verify and skip if so).

### Commit 2 — `@Observable` migration of `Library/` stores

Convert each `ObservableObject` to `@Observable`. Drop `@Published` annotations. Drop `import Combine` from any file whose only Combine use was `@Published`. For singletons (`*Store.shared`, `RuntimeSettings.shared`), the pattern is:

```swift
@Observable @MainActor
public final class HostSettingsStore {
    public static let shared = HostSettingsStore()
    public var autoConnect: AutoConnectConfig { didSet { persist() } }
    public var logRetention: LogRetention { didSet { persist() } }

    @ObservationIgnored private var loaded = false

    private init() {
        let stored = JSONFileStore.load(...)
        self.autoConnect = stored.autoConnect
        self.logRetention = stored.logRetention
        self.loaded = true   // didSet can be cheap; the persist guard is in persist()
    }

    private func persist() {
        guard loaded else { return }
        // ... same as before, write file + post notification
    }
}
```

Key swap rules:

- `final class X: ObservableObject` → `@Observable final class X`
- `@Published public var foo` → `public var foo`
- `@Published public private(set) var foo` → `public private(set) var foo`
- Any `private var bag = Set<AnyCancellable>()` removed if no Combine left
- Combine init sinks rewritten as `didSet` calling `persist()` / `prune()`. The Combine `.dropFirst()` effect is preserved by the `loaded` flag set at end of init.

### Commit 3 — View consumer migration in `ApplicationLibrary/` + `Pcat/`

Sweep every `ApplicationLibrary/*.swift` and `Pcat/*.swift`:

- `@StateObject private var x = X()` → `@State private var x = X()`
- `@ObservedObject var x: X` → `@Bindable var x: X` if the view passes bindings; plain `var x: X` if it only reads.
- `@EnvironmentObject private var env: ExtensionEnvironment` → `@Environment(ExtensionEnvironment.self) private var env`
- `MainView`: `.environmentObject(env)` chain becomes `.environment(env)` chain. The "same observable identity" comment becomes accurate without contortions because `@Observable` types are reference-typed and `.environment(_:)` propagates them.
- `MainView` declares `@State private var environment = ExtensionEnvironment()` (not `@StateObject`).

`@Bindable` works against an existing `@Observable` reference, so view bodies that today write `Toggle("…", isOn: $store.autoConnect.enabled)` keep their `$store.…` syntax with no change once `var store: HostSettingsStore` is declared `@Bindable`.

### Commit 4 — Coordinator migration: Combine sinks → observation tracking

Touch only `Library/ExtensionCoordinators.swift`:

- `VPNLifecycleCoordinator.start()`:
  ```swift
  observationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled, let self {
          let status = withObservationTracking {
              self.profile.status
          } onChange: { /* re-arm */ }
          self.apply(status)
          // suspend until next change — use AsyncStream of property changes
      }
  }
  ```
  Practical pattern: a small `Observed.values(for:)` helper that wraps `withObservationTracking` in an `AsyncStream`. (See "Helper to add" below.)
- `TrafficCoordinator.start()`: same pattern, observing `commandClient.traffic`. Dedupe by tracking last value to preserve `removeDuplicates()` semantics.
- `SettingsChangeCoordinator.start()` and `AutoConnectCoordinator.start()` are converted in commit 5 (notifications, not Combine).

**Helper to add** — `Library/Observed.swift`:

```swift
import Foundation
import Observation

/// Wraps `withObservationTracking` in an `AsyncStream` so consumers
/// can `for await value in Observed.values { ... }` instead of
/// re-arming the tracking by hand. Emits the initial value, then
/// every time the closure's read set changes. Stream terminates
/// (and the inner observation Task cancels) when the consumer
/// breaks out of its for-loop or its enclosing Task is cancelled.
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

Semantics match `$x.sink`: emit the initial value, then every change. To replicate `dropFirst()`, the consumer drops the first iterate. To replicate `removeDuplicates()`, the consumer keeps the last value and skips equal yields.

### Commit 5 — NotificationCenter → AsyncSequence

In `SettingsChangeCoordinator`, `AutoConnectCoordinator`, and `ExtensionProfile`:

- Replace `addObserver(forName:object:queue:using:)` + `bag.add(...)` with `Task { for await note in NotificationCenter.default.notifications(named:) { ... } }`.
- Each coordinator stores its `Task`s in an array. `deinit` cancels them all.
- `Library/ObservationBag.swift` is deleted (no remaining callers).
- `import Combine` is removed from any file that had it only for the `Cancellable` machinery.

### Commit 6 — XCTest → Swift Testing

Mechanical conversion of `Tests/LibraryTests/*.swift`:

```swift
import XCTest
final class FooTests: XCTestCase {
    func test_x() throws { XCTAssertEqual(a, b) }
}
```
becomes
```swift
import Testing
@Suite struct FooTests {
    @Test func x() throws { #expect(a == b) }
}
```

- `XCTAssertEqual(a, b)` → `#expect(a == b)`
- `XCTAssertNil(a)` → `#expect(a == nil)`
- `XCTAssertTrue(a)` → `#expect(a)`
- `XCTAssertFalse(a)` → `#expect(!a)`
- `XCTAssertThrowsError(try f()) { error in ... }` → `#expect(throws: ErrType.self) { try f() }` or the explicit `do { try f(); Issue.record("expected throw") } catch { ... }` pattern when type assertions matter.
- `XCTAssertEqual(a, b, accuracy: …)` → `#expect(abs(a - b) < eps)`.
- Async tests stay `async`; setup runs in `init()`.

`project.yml` test target: confirm `IPHONEOS_DEPLOYMENT_TARGET: "17.0"` is sufficient for Swift Testing — it is.

### Commit 7 — Typed throws + helper audit

- `MihomoController`: each method `throws -> T` → `throws(MihomoControllerError) -> T`. The internal `perform(_:)` helper is annotated to match.
- Audit `withTimeout` in `ExtensionProfile`: only one caller (`sendCommand`); leave inline.
- Audit `AsyncOneShot`: leave (no stdlib alternative).
- Audit `ManagedResume`: leave (no stdlib alternative for one-shot continuation).
- Audit `ExponentialBackoff`: leave (intentional design).

## Risks

- **gomobile bridge thread reentrancy**: `CommandClient` is called by Go threads via `ClientBridge`. The current `Task { @MainActor [weak owner] in ... }` shape is the right Swift 6 pattern; verify after migration that no warnings appear.
- **Order-of-init in `@Observable` singletons**: `didSet` doesn't fire during `init` (Swift semantics), so the `loaded` flag is belt-and-suspenders. Tested by re-running `JSONFileStoreTests` round-trip.
- **`@Bindable` on environment-injected stores**: SwiftUI's `@Environment(X.self)` returns `X` directly; for two-way bindings the view re-declares it as `@Bindable var store = env.store` inside the body, or uses `@Bindable` at property level. The current view shapes don't require many bindings (`HostSettingsStore.autoConnect.enabled` toggle is the main case) — handled per-view in commit 3.
- **Swift Testing on the simulator** with the App Group entitlement absent in tests: the existing `Tests/LibraryTests/` already works around this via `FilePath` falling back to `Documents`. No change needed.
- **`Observed.values` cancellation**: handled in the helper itself — `continuation.onTermination` cancels the producer Task, which short-circuits the next loop iteration. Verified by writing a small test: spin up a stream, cancel the iterating Task, mutate the source, observe the producer doesn't fire.

## Verification

- Per commit: `make project && xcodebuild -scheme Pcat -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build` (or via XcodeBuildMCP `build_sim`).
- After commit 6: `xcodebuild test -scheme Library` (or `test_sim`).
- After commit 5 (UI-touching landed): manual smoke on simulator — connect/disconnect, edit profile, watch logs, view stats.
- Final: `git log --oneline main..HEAD` shows seven small commits with a coherent narrative; `git grep -nE "ObservableObject|@Published|import Combine"` returns nothing in `Library/`, `ApplicationLibrary/`, `Pcat/`, `PcatExtension/`.
