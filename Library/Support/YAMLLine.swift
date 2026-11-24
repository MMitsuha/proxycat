import Foundation

struct YAMLLine {
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
