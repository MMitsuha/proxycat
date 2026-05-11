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

public enum MitmProfileConfigYAML {
    public static func config(from profileYAML: String) -> MitmProfileConfig {
        let lines = YAMLLine.split(profileYAML)
        guard let range = mitmBlockRange(in: lines) else {
            return MitmProfileConfig()
        }
        return parseBlock(lines[range].map(\.text))
    }

    public static func replacingConfig(
        in profileYAML: String,
        with config: MitmProfileConfig
    ) throws -> String {
        try validate(config)

        var lines = YAMLLine.split(profileYAML)
        let lineEnding = preferredLineEnding(in: lines)
        let block = renderBlock(config, lineEnding: lineEnding)
        let blockLines = YAMLLine.split(block)

        if let range = mitmBlockRange(in: lines) {
            lines.replaceSubrange(range, with: blockLines)
            return YAMLLine.join(lines)
        }

        var output = profileYAML
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block
        }
        if !output.hasSuffix("\n") {
            output += lineEnding
        }
        if !output.hasSuffix("\n\n") && !output.hasSuffix("\r\n\r\n") {
            output += lineEnding
        }
        return output + block
    }

    public static func parsePortsText(_ text: String) throws -> [UInt16] {
        let parts = text
            .split { character in
                character == "," || character == "\n" || character == "\r" || character == " " || character == "\t"
            }
            .map(String.init)

        var ports: [UInt16] = []
        var seen = Set<UInt16>()
        for part in parts {
            guard let intValue = Int(part), (1...65_535).contains(intValue) else {
                throw MitmProfileConfigError.invalidPort(part)
            }
            let port = UInt16(intValue)
            if seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    public static func formatPorts(_ ports: [UInt16]) -> String {
        ports.map(String.init).joined(separator: ", ")
    }

    public static func parseDomainsText(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: ",", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func formatDomains(_ domains: [String]) -> String {
        domains.joined(separator: "\n")
    }

    public static func normalizedRulesYAML(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        trimBlankEdges(&lines)
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let key = directKey(in: lines[firstIndex]),
              key.name == "rules" else {
            return lines.joined(separator: "\n")
        }

        let childLines = Array(lines[(firstIndex + 1)...]).map { line in
            line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
        }
        var normalized = childLines
        trimBlankEdges(&normalized)
        return normalized.joined(separator: "\n")
    }

    public static func parseRulesYAML(_ text: String) -> [MitmRewriteRule] {
        let normalized = normalizedRulesYAML(text)
        guard !normalized.isEmpty else { return [] }

        var rules: [MitmRewriteRule] = []
        var fields: [String: String] = [:]

        func flushRule() {
            guard !fields.isEmpty else { return }
            if let rule = rewriteRule(from: fields) {
                rules.append(rule)
            }
            fields = [:]
        }

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("-") {
                flushRule()
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if let field = ruleField(in: String(rest)) {
                    fields[field.name] = field.value
                }
            } else if let field = ruleField(in: trimmed) {
                fields[field.name] = field.value
            }
        }

        flushRule()
        return rules
    }

    private static func validate(_ config: MitmProfileConfig) throws {
        if config.isEnabled && config.ports.isEmpty {
            throw MitmProfileConfigError.missingEnabledPort
        }
        for rule in config.rules {
            if rule.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MitmProfileConfigError.missingRuleURL
            }
            if rule.action.requiresNewValue,
               rule.new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MitmProfileConfigError.missingRuleNewValue(rule.action.rawValue)
            }
        }
    }

    private static func renderBlock(_ config: MitmProfileConfig, lineEnding: String) -> String {
        var lines = [
            "mitm:",
            "  enable: \(config.isEnabled ? "true" : "false")",
        ]

        let domains = config.domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !domains.isEmpty {
            lines.append("  domain:")
            lines.append(contentsOf: domains.map { "    - \(quotedYAMLString($0))" })
        }

        if !config.ports.isEmpty {
            lines.append("  ports:")
            lines.append(contentsOf: config.ports.map { "    - \($0)" })
        }

        lines.append("  encrypted-sni-policy: \(config.encryptedSNIPolicy.rawValue)")

        if !config.rules.isEmpty {
            lines.append("  rules:")
            lines.append(contentsOf: config.rules.flatMap(renderRule))
        }

        return lines.joined(separator: lineEnding) + lineEnding
    }

    private static func renderRule(_ rule: MitmRewriteRule) -> [String] {
        var lines = [
            "    - url: \(quotedYAMLString(rule.url))",
            "      action: \(quotedYAMLString(rule.action.rawValue))",
        ]

        if rule.action.usesPatternReplacement,
           !rule.old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("      old: \(quotedYAMLString(rule.old))")
        }
        if rule.action.requiresNewValue {
            lines.append("      new: \(quotedYAMLString(rule.new))")
        }
        return lines
    }

    private static func parseBlock(_ blockLines: [String]) -> MitmProfileConfig {
        guard !blockLines.isEmpty else { return MitmProfileConfig() }
        let body = blockLines.dropFirst().map { line in
            line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
        }

        var config = MitmProfileConfig(isEnabled: false, domains: [], ports: [], encryptedSNIPolicy: .skip)
        if let value = scalarValue(for: "enable", in: Array(body)) {
            config.isEnabled = boolValue(value) ?? false
        }
        if let value = scalarValue(for: "encrypted-sni-policy", in: Array(body)) {
            let policy = unquoteYAMLScalar(value).lowercased()
            config.encryptedSNIPolicy = MitmProfileConfig.EncryptedSNIPolicy(rawValue: policy) ?? .skip
        }
        config.domains = stringList(for: "domain", in: Array(body))
        config.ports = stringList(for: "ports", in: Array(body)).compactMap {
            UInt16(unquoteYAMLScalar($0))
        }
        config.rules = parseRulesYAML(rawChildBlock(for: "rules", in: Array(body)))
        return config
    }

    private static func rewriteRule(from fields: [String: String]) -> MitmRewriteRule? {
        guard let url = fields["url"], !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let actionValue = fields["action"] ?? MitmRewriteRule.Action.reject.rawValue
        guard let action = MitmRewriteRule.Action(rawValue: actionValue) else {
            return nil
        }
        return MitmRewriteRule(
            url: url,
            action: action,
            old: fields["old"] ?? "",
            new: fields["new"] ?? ""
        )
    }

    private static func ruleField(in line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let valueStart = trimmed.index(after: colon)
        let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
        return (name, unquoteYAMLScalar(value))
    }

    private static func scalarValue(for key: String, in lines: [String]) -> String? {
        guard let range = directKeyRange(for: key, in: lines) else { return nil }
        return range.value
    }

    private static func stringList(for key: String, in lines: [String]) -> [String] {
        guard let range = directKeyRange(for: key, in: lines) else { return [] }
        if let inlineItems = inlineList(range.value) {
            return inlineItems.map(unquoteYAMLScalar).filter { !$0.isEmpty }
        }

        return lines[(range.index + 1)..<range.end]
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("-") else { return nil }
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                return unquoteYAMLScalar(String(value))
            }
    }

    private static func rawChildBlock(for key: String, in lines: [String]) -> String {
        guard let range = directKeyRange(for: key, in: lines) else { return "" }
        if inlineList(range.value) != nil {
            return ""
        }

        var childLines = lines[(range.index + 1)..<range.end].map { line in
            line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
        }
        trimBlankEdges(&childLines)
        return childLines.joined(separator: "\n")
    }

    private static func directKeyRange(
        for name: String,
        in lines: [String]
    ) -> (index: Int, end: Int, value: String)? {
        for index in lines.indices {
            guard let key = directKey(in: lines[index]), key.name == name else {
                continue
            }
            var end = index + 1
            while end < lines.count {
                if directKey(in: lines[end]) != nil {
                    break
                }
                end += 1
            }
            return (index, end, key.value)
        }
        return nil
    }

    private static func directKey(in line: String) -> (name: String, value: String)? {
        guard leadingWhitespaceCount(line) == 0 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colon])
        guard !name.isEmpty else { return nil }
        let valueStart = trimmed.index(after: colon)
        return (name, String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces))
    }

    private static func boolValue(_ raw: String) -> Bool? {
        switch unquoteYAMLScalar(raw).lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    private static func inlineList(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in inner {
            if quote == "\"", escaped {
                current.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if let activeQuote = quote, character == activeQuote {
                current.append(character)
                quote = nil
                continue
            }
            if quote == nil, character == "'" || character == "\"" {
                quote = character
                current.append(character)
                continue
            }
            if quote == nil, character == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        items.append(current.trimmingCharacters(in: .whitespaces))
        return items
    }

    private static func unquoteYAMLScalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("'") {
            value.removeFirst()
            if value.hasSuffix("'") {
                value.removeLast()
            }
            return value.replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\"") {
            value.removeFirst()
            if value.hasSuffix("\"") {
                value.removeLast()
            }
            return value
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quotedYAMLString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func mitmBlockRange(in lines: [YAMLLine]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { isTopLevelKey($0.text, named: "mitm") }) else {
            return nil
        }
        var end = start + 1
        while end < lines.count {
            if isTopLevelBoundary(lines[end].text) {
                break
            }
            end += 1
        }
        return start..<end
    }

    private static func isTopLevelKey(_ line: String, named key: String) -> Bool {
        guard leadingWhitespaceCount(line) == 0 else { return false }
        let trimmed = stripByteOrderMark(line).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        return trimmed.hasPrefix("\(key):")
    }

    private static func isTopLevelBoundary(_ line: String) -> Bool {
        guard leadingWhitespaceCount(line) == 0 else { return false }
        let trimmed = stripByteOrderMark(line).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return true
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func stripByteOrderMark(_ line: String) -> String {
        guard line.unicodeScalars.first?.value == 0xFEFF else { return line }
        return String(line.dropFirst())
    }

    private static func preferredLineEnding(in lines: [YAMLLine]) -> String {
        lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
    }

    private static func trimBlankEdges(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
    }
}

private struct YAMLLine {
    var text: String
    var terminator: String

    static func split(_ text: String) -> [YAMLLine] {
        guard !text.isEmpty else { return [] }

        var lines: [YAMLLine] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let newline = text[start...].firstIndex(of: "\n") else {
                lines.append(YAMLLine(text: String(text[start...]), terminator: ""))
                break
            }

            var lineText = String(text[start..<newline])
            var terminator = "\n"
            if lineText.hasSuffix("\r") {
                lineText.removeLast()
                terminator = "\r\n"
            }
            lines.append(YAMLLine(text: lineText, terminator: terminator))
            start = text.index(after: newline)
        }
        return lines
    }

    static func join(_ lines: [YAMLLine]) -> String {
        lines.map { $0.text + $0.terminator }.joined()
    }
}
