import Foundation

/// Identifies a per-session log file dropped by the Network Extension
/// into the App Group's `Logs/` directory and captures everything the
/// host UI needs to display it. The session start time is recovered
/// from the filename (`(mihomo|proxycat)-YYYYMMDD-HHMMSS[-N].log`)
/// rather than the file's modification date, so the title stays
/// stable for the file the extension is actively writing into.
public struct SavedLogFileInfo: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case mihomo
        case proxycat

        /// The on-disk filename prefix the writer uses. Mihomo's Go
        /// persistence layer hard-codes "mihomo-"; the Swift extension
        /// layer reads its value from `AppConfiguration` so the
        /// literal lives in exactly one place per language.
        public var fileNamePrefix: String {
            switch self {
            case .mihomo: return "mihomo-"
            case .proxycat: return AppConfiguration.proxyCatLogFilePrefix
            }
        }

        /// Human label used in the row badge. Capitalisation matches
        /// how each project styles its own name.
        public var displayName: String {
            switch self {
            case .mihomo: return "mihomo"
            case .proxycat: return "ProxyCat"
            }
        }

        /// Cheap prefix-only check — used by the retention pruner and
        /// other call sites that only need to know "is this one of
        /// our files" without parsing the timestamp.
        public static func matching(filename: String) -> Kind? {
            guard filename.hasSuffix(".log") else { return nil }
            return Kind.allCases.first { filename.hasPrefix($0.fileNamePrefix) }
        }
    }

    public let kind: Kind
    public let url: URL
    public let size: Int64
    /// The session start time recovered from the filename. Local time
    /// because the writer (Go and Swift both) formats `time.Now()` /
    /// `Date()` without an explicit timezone marker; parsing in the
    /// device's current timezone keeps "session 14:00" reading as
    /// 14:00 on the device that produced it.
    public let startedAt: Date
    /// File mtime at the moment this struct was built. Kept as
    /// secondary info — the LIVE file's mtime drifts every line so we
    /// never sort by it, but a non-LIVE file's mtime is a useful "how
    /// long did the session run" hint.
    public let modifiedAt: Date
    public let isActive: Bool

    public var id: String { url.path }
    public var fileName: String { url.lastPathComponent }

    /// Parses one URL into a SavedLogFileInfo. Returns nil if the
    /// filename doesn't match `{prefix}YYYYMMDD-HHMMSS[-N].log` —
    /// anything else dropped in the directory (a user-imported text
    /// file, a future feature's artefact) is left alone instead of
    /// being silently counted as a session.
    public static func parse(
        url: URL,
        size: Int64,
        modifiedAt: Date,
        isActive: Bool
    ) -> SavedLogFileInfo? {
        guard let kind = Kind.matching(filename: url.lastPathComponent) else {
            return nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        let rest = name.dropFirst(kind.fileNamePrefix.count)
        // `rest` is either "YYYYMMDD-HHMMSS" or "YYYYMMDD-HHMMSS-N".
        // Take exactly the first two dash-separated chunks; reject
        // anything that doesn't have both.
        let parts = rest.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let timestamp = "\(parts[0])-\(parts[1])"
        guard let startedAt = Self.filenameDateFormatter.date(from: timestamp) else {
            return nil
        }
        return SavedLogFileInfo(
            kind: kind,
            url: url,
            size: size,
            startedAt: startedAt,
            modifiedAt: modifiedAt,
            isActive: isActive
        )
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

public struct SavedLogLine: Identifiable, Equatable, Sendable {
    public let number: Int
    public let text: String

    public var id: Int { number }

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

public struct SavedLogDocument: Equatable, Sendable {
    public let size: Int64
    public let lines: [SavedLogLine]
    public let replacedInvalidUTF8: Bool

    public init(size: Int64, lines: [SavedLogLine], replacedInvalidUTF8: Bool) {
        self.size = size
        self.lines = lines
        self.replacedInvalidUTF8 = replacedInvalidUTF8
    }
}

public enum SavedLogFileReader {
    public static func load(path: String) throws -> SavedLogDocument {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoded = decodeUTF8(data)
        return SavedLogDocument(
            size: Int64(values.fileSize ?? data.count),
            lines: makeLines(from: decoded.text),
            replacedInvalidUTF8: decoded.replacedInvalidUTF8
        )
    }

    static func decodeUTF8(_ data: Data) -> SavedLogDecodeResult {
        let payload: Data
        if data.starts(with: Data([0xEF, 0xBB, 0xBF])) {
            payload = Data(data.dropFirst(3))
        } else {
            payload = data
        }

        if let exact = String(data: payload, encoding: .utf8) {
            return SavedLogDecodeResult(text: exact, replacedInvalidUTF8: false)
        }
        return SavedLogDecodeResult(
            text: String(decoding: payload, as: UTF8.self),
            replacedInvalidUTF8: true
        )
    }

    static func makeLines(from text: String) -> [SavedLogLine] {
        guard !text.isEmpty else { return [] }
        var rawLines = text.components(separatedBy: .newlines)
        if rawLines.last == "" {
            rawLines.removeLast()
        }
        return rawLines.enumerated().map { index, line in
            SavedLogLine(number: index + 1, text: line)
        }
    }
}

struct SavedLogDecodeResult: Equatable {
    let text: String
    let replacedInvalidUTF8: Bool
}
