import Library
import SwiftUI

public struct ProxiesView: View {
    @Environment(ExtensionProfile.self) private var profile
    @State private var store: ProxiesStore

    public init(transport: any ControllerTransport) {
        _store = State(initialValue: ProxiesStore(transport: transport))
    }

    private var isReady: Bool {
        profile.isConnected
    }

    private func syncIfReady() async {
        if isReady {
            await store.refresh()
        } else {
            store.reset()
        }
    }

    public var body: some View {
        Group {
            if !profile.isConnected {
                ContentUnavailableView(
                    localizedTitle: "Connect first to manage proxies",
                    systemImage: "powerplug.portrait"
                )
            } else {
                content
            }
        }
        .navigationTitle("Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await syncIfReady() }
        // The view stays mounted across tunnel toggles (TabView keeps
        // tabs alive). Without this the cached `store.groups` would
        // persist after a disconnect, and a tap on reconnect would
        // briefly fire actions against the previous controller state.
        // The "Disable Web Controller" toggle no longer affects this
        // view — the native controller dials a sibling Unix socket
        // that's always bound while the tunnel is up.
        .onChange(of: profile.isConnected) { _, _ in Task { await syncIfReady() } }
        // The empty-state ContentUnavailableView already covers the
        // first-load failure, but once `groups` has data, refresh /
        // select / testGroup failures only update `loadError` — which
        // would otherwise be invisible. Surface those as an alert so a
        // tap that fails doesn't read as "tap did nothing".
        .errorAlert(
            Binding(
                get: { store.groups.isEmpty ? nil : store.loadError },
                set: { newValue in if newValue == nil { store.clearLoadError() } }
            ),
            title: "Action failed"
        )
    }

    @ViewBuilder
    private var content: some View {
        if let err = store.loadError, store.groups.isEmpty {
            ProxyCatLoadFailureView(message: err) {
                Task { await store.refresh() }
            }
        } else if store.groups.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.groups, id: \.name) { group in
                    Section {
                        if !store.isCollapsed(group.name) {
                            // Stable per-position id keeps row identity tied
                            // to the slot rather than the proxy name. Names
                            // within a group are unique today, but the
                            // offset-based id is robust against future relay
                            // groups that may surface the same name twice
                            // and avoids row recreation when only the
                            // selected node changes.
                            let entries = Array((group.all ?? []).enumerated())
                            ForEach(entries, id: \.offset) { _, name in
                                ProxyRow(
                                    name: name,
                                    node: store.nodeMap[name],
                                    isSelected: group.now == name,
                                    isInteractive: group.isSelectable,
                                    isPending: store.isSelecting(group: group.name, node: name),
                                    onTap: {
                                        Task { await store.select(group: group, name: name) }
                                    }
                                )
                            }
                        }
                    } header: {
                        ProxyGroupHeader(
                            group: group,
                            isCollapsed: store.isCollapsed(group.name),
                            isTesting: store.groupTesting.contains(group.name),
                            onToggle: { withAnimation { store.toggleCollapsed(group.name) } },
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
    }

}
