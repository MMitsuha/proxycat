import Foundation

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
