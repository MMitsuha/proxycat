import Combine
import Foundation

/// Single object injected as @EnvironmentObject so views can reach the VPN
/// profile and the streaming command client without prop-drilling.
@MainActor
public final class ExtensionEnvironment: ObservableObject {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    /// Persisted across log view appearances so the user's search term
    /// survives navigation. Mirrors sing-box-for-apple's logSearchText.
    @Published public var logSearchText: String = ""

    public init() {
        self.profile = ExtensionProfile()
        self.commandClient = CommandClient()
    }

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        self.profile = profile
        self.commandClient = commandClient
    }

    public func bootstrap() async {
        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }
    }

    public func connect() {
        commandClient.connect()
    }

    public func disconnect() {
        commandClient.disconnect()
    }
}
