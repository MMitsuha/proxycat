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
