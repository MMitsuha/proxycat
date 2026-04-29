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
    /// Group names whose node list is currently collapsed in the UI.
    @Published public private(set) var collapsed: Set<String> = []

    private let controller: MihomoController
    private let defaults: UserDefaults
    private static let collapsedKey = "io.proxycat.proxies.collapsed"

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
}

private func selectingKey(group: String, node: String) -> String {
    "\(group)/\(node)"
}
