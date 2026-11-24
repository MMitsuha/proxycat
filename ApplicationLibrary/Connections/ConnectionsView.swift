import Library
import SwiftUI

public struct ConnectionsView: View {
    @Environment(ExtensionProfile.self) private var profile

    @State private var store: ConnectionsStore
    @State private var confirmCloseAll: Bool = false
    @State private var detail: Connection?

    public init(transport: any ControllerTransport) {
        _store = State(initialValue: ConnectionsStore(transport: transport))
    }

    public var body: some View {
        @Bindable var store = store
        return Group {
            if !profile.isConnected {
                ContentUnavailableView(
                    localizedTitle: "Connect first to view connections",
                    systemImage: "powerplug.portrait"
                )
            } else {
                content
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncStreaming() }
        .onDisappear { store.stop() }
        // Defensive: if the tunnel drops mid-view, stop the poll loop
        // and let the empty state take over instead of letting the
        // store hammer a closed socket. The "Disable Web Controller"
        // toggle no longer affects this view — the native poller
        // dials a sibling Unix socket that's always bound while the
        // tunnel is up.
        .onChange(of: profile.isConnected) { _, _ in syncStreaming() }
        .sheet(item: $detail) { conn in
            ConnectionDetailSheet(connection: conn)
        }
        // Once the list has data, close / closeAll / decode failures
        // only update `loadError` and the empty-state ContentUnavailable
        // branch can't render — the user would otherwise see "swipe did
        // nothing". Surface those as an alert once data is on screen.
        .errorAlert(
            Binding(
                get: { store.connections.isEmpty ? nil : store.loadError },
                set: { newValue in if newValue == nil { store.clearLoadError() } }
            ),
            title: "Action failed"
        )
    }

    private func syncStreaming() {
        if profile.isConnected {
            store.start()
        } else {
            store.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            summaryBar
            if let err = store.loadError, store.connections.isEmpty {
                ContentUnavailableView {
                    Label("Could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else if store.connections.isEmpty {
                if store.isStreaming {
                    ContentUnavailableView(localizedTitle: "No active connections", systemImage: "tray")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(store.filteredConnections) { conn in
                        ConnectionRow(connection: conn)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = conn }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await store.close(id: conn.id) }
                                } label: {
                                    Label("Close", systemImage: "xmark.circle")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $store.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .overlay {
                    // The list branch is taken whenever there are
                    // connections; if the user types a query that matches
                    // nothing, the List would otherwise render blank and
                    // look like the data vanished.
                    if store.filteredConnections.isEmpty {
                        ContentUnavailableView(
                            localizedTitle: "No matching connections",
                            systemImage: "magnifyingglass",
                            localizedDescription: "Try another search term."
                        )
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmCloseAll = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .disabled(store.connections.isEmpty)
            }
        }
        .alert("Close all connections?", isPresented: $confirmCloseAll) {
            Button("Close all", role: .destructive) {
                Task { await store.closeAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            Label {
                // "\(Int) active" auto-extracts to key "%lld active",
                // and the catalog has a translation under that key.
                Text("\(store.connections.count) active connections")
                    .font(.subheadline.weight(.medium))
            } icon: {
                Circle()
                    .fill(store.isStreaming ? Color.green : .gray)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Label(ByteFormatter.string(store.uploadTotal), systemImage: "arrow.up")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Label(ByteFormatter.string(store.downloadTotal), systemImage: "arrow.down")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
