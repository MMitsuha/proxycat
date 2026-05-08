import Foundation
import Observation

/// View-model for `ProxiesView`. One instance per view appearance; not a
/// shared singleton. Holds proxy-group metadata plus in-flight bookkeeping
/// so the UI can reflect "selecting…" and "testing…" states.
@MainActor @Observable
public final class ProxiesStore {
    public private(set) var groups: [Proxy] = []
    public private(set) var nodeMap: [String: Proxy] = [:]
    public private(set) var loadError: String?
    public private(set) var isRefreshing: Bool = false
    /// Group names with an in-flight health-check.
    public private(set) var groupTesting: Set<String> = []
    /// `"<group>/<node>"` pairs with an in-flight selection.
    public private(set) var selecting: Set<String> = []
    /// Group names whose node list is currently collapsed in the UI.
    public private(set) var collapsed: Set<String> = []

    @ObservationIgnored private let controller: MihomoController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let collapsedKey = "io.proxycat.proxies.collapsed"

    /// Bumped by `reset()`. Async work captures the value at start and
    /// discards its writes if the token has moved on, so a `/proxies`
    /// or `/group/.../delay` response that returns after a disconnect
    /// can't repopulate `groups` or surface a stale error against the
    /// new controller state.
    @ObservationIgnored private var generation: Int = 0

    public init(
        controller: MihomoController = MihomoController(),
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.collapsedKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.collapsed = Set(arr)
        }
    }

    /// `GET /proxies` and split the response into groups vs nodes. Groups
    /// are sorted by `proxies["GLOBAL"].all`, matching metacubexd —
    /// otherwise the order is whatever Go's map iteration produced this
    /// run, which would shuffle on every refresh.
    public func refresh() async {
        let gen = generation
        isRefreshing = true
        defer {
            // Only clear the spinner if our generation is still current —
            // otherwise reset() (or a follow-up refresh) owns this flag.
            if gen == generation { isRefreshing = false }
        }
        do {
            let proxies = try await controller.proxies()
            guard gen == generation else { return }
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
            guard gen == generation else { return }
            self.loadError = error.localizedDescription
        }
    }

    /// Pick a node inside a manually-selectable group (Selector / URLTest /
    /// Fallback — see `Proxy.isSelectable`). LoadBalance and leaf proxies
    /// would 400 on `PUT /proxies/{name}`; the view also hides the tap
    /// affordance for them, but we keep the guard so a misuse of the API
    /// is silent rather than surfacing a 400 the user has to read.
    public func select(group: Proxy, name: String) async {
        guard group.isSelectable else { return }
        let gen = generation
        let key = selectingKey(group: group.name, node: name)
        selecting.insert(key)
        defer {
            if gen == generation { selecting.remove(key) }
        }
        do {
            try await controller.select(group: group.name, name: name)
            guard gen == generation else { return }
            await refresh()
        } catch {
            guard gen == generation else { return }
            loadError = error.localizedDescription
        }
    }

    /// Run a health-check on every node in a group. Re-fetches `/proxies`
    /// after to pick up the updated `history` arrays — the delay endpoint
    /// returns just `name → ms` and we want consistent UI state. Passes
    /// the group's own `testUrl`/`timeout`/`expectedStatus` through so a
    /// custom probe target on the profile is honored; falls back to the
    /// controller defaults only when the group leaves them unset.
    public func testGroup(_ group: Proxy) async {
        let gen = generation
        groupTesting.insert(group.name)
        defer {
            if gen == generation { groupTesting.remove(group.name) }
        }
        do {
            _ = try await controller.groupDelay(
                name: group.name,
                url: group.testUrl,
                timeoutMs: group.timeout,
                expectedStatus: group.expectedStatus
            )
            guard gen == generation else { return }
            await refresh()
        } catch {
            guard gen == generation else { return }
            loadError = error.localizedDescription
        }
    }

    /// Drop cached groups and any error banner — used when the view
    /// transitions away from "connected + controller enabled" so the next
    /// time the user comes back the screen doesn't briefly show stale
    /// rows targeting a torn-down controller. Bumps the generation token
    /// so any in-flight refresh/select/testGroup discards its writes.
    public func reset() {
        generation &+= 1
        groups = []
        nodeMap = [:]
        loadError = nil
        groupTesting = []
        selecting = []
        isRefreshing = false
    }

    public func isSelecting(group: String, node: String) -> Bool {
        selecting.contains(selectingKey(group: group, node: node))
    }

    public func isCollapsed(_ group: String) -> Bool {
        collapsed.contains(group)
    }

    public func toggleCollapsed(_ group: String) {
        if collapsed.contains(group) {
            collapsed.remove(group)
        } else {
            collapsed.insert(group)
        }
        let arr = Array(collapsed).sorted()
        if let data = try? JSONEncoder().encode(arr) {
            defaults.set(data, forKey: Self.collapsedKey)
        }
    }

    /// Lets the view dismiss an error alert. The store keeps `loadError`
    /// `private(set)` so it can't be mutated arbitrarily from outside, but
    /// an alert binding does need to clear on user dismissal.
    public func clearLoadError() {
        loadError = nil
    }
}

private func selectingKey(group: String, node: String) -> String {
    "\(group)/\(node)"
}
