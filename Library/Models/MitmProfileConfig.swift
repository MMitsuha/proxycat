import Foundation

public struct MitmProfileConfig: Equatable, Sendable {
    public enum EncryptedSNIPolicy: String, CaseIterable, Identifiable, Sendable {
        case skip
        case mitm
        case reject

        public var id: String { rawValue }
    }

    public var isEnabled: Bool
    public var domains: [String]
    public var ports: [UInt16]
    public var encryptedSNIPolicy: EncryptedSNIPolicy
    public var rules: [MitmRewriteRule]

    public init(
        isEnabled: Bool = false,
        domains: [String] = [],
        ports: [UInt16] = [80, 443],
        encryptedSNIPolicy: EncryptedSNIPolicy = .skip,
        rules: [MitmRewriteRule] = []
    ) {
        self.isEnabled = isEnabled
        self.domains = domains
        self.ports = ports
        self.encryptedSNIPolicy = encryptedSNIPolicy
        self.rules = rules
    }

    public init(
        isEnabled: Bool = false,
        domains: [String] = [],
        ports: [UInt16] = [80, 443],
        encryptedSNIPolicy: EncryptedSNIPolicy = .skip,
        rulesYAML: String
    ) {
        self.init(
            isEnabled: isEnabled,
            domains: domains,
            ports: ports,
            encryptedSNIPolicy: encryptedSNIPolicy,
            rules: MitmProfileConfigYAML.parseRulesYAML(rulesYAML)
        )
    }
}

public struct MitmRewriteRule: Identifiable, Sendable {
    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case reject
        case reject200 = "reject-200"
        case rejectImg = "reject-img"
        case rejectDict = "reject-dict"
        case rejectArray = "reject-array"
        case redirect302 = "302"
        case redirect307 = "307"
        case requestHeader = "request-header"
        case requestBody = "request-body"
        case responseHeader = "response-header"
        case responseBody = "response-body"

        public var id: String { rawValue }

        public var usesPatternReplacement: Bool {
            switch self {
            case .requestHeader, .requestBody, .responseHeader, .responseBody:
                return true
            case .reject, .reject200, .rejectImg, .rejectDict, .rejectArray, .redirect302, .redirect307:
                return false
            }
        }

        public var requiresNewValue: Bool {
            switch self {
            case .redirect302, .redirect307, .requestHeader, .requestBody, .responseHeader, .responseBody:
                return true
            case .reject, .reject200, .rejectImg, .rejectDict, .rejectArray:
                return false
            }
        }
    }

    public let id: UUID
    public var url: String
    public var action: Action
    public var old: String
    public var new: String

    public init(
        id: UUID = UUID(),
        url: String = "",
        action: Action = .reject,
        old: String = "",
        new: String = ""
    ) {
        self.id = id
        self.url = url
        self.action = action
        self.old = old
        self.new = new
    }
}

extension MitmRewriteRule: Equatable {
    public static func == (lhs: MitmRewriteRule, rhs: MitmRewriteRule) -> Bool {
        lhs.url == rhs.url
            && lhs.action == rhs.action
            && lhs.old == rhs.old
            && lhs.new == rhs.new
    }
}

public enum MitmProfileConfigError: LocalizedError, Equatable {
    case invalidPort(String)
    case missingEnabledPort
    case missingRuleURL
    case missingRuleNewValue(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            return String(localized: "MITM port \(value) is not valid.", bundle: .main)
        case .missingEnabledPort:
            return String(localized: "Add at least one MITM port before enabling MITM.", bundle: .main)
        case .missingRuleURL:
            return String(localized: "Every MITM rewrite rule needs a URL pattern.", bundle: .main)
        case let .missingRuleNewValue(action):
            return String(localized: "MITM action \(action) needs a replacement value.", bundle: .main)
        }
    }
}
