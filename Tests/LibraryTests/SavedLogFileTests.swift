import Foundation
import Testing
@testable import Library

@Suite struct SavedLogFileTests {
    @Test func decodesUTF8ChineseWithoutReplacement() {
        let text = "2026-05-11T02:00:00.000 [info] 连接成功，节点=日本\n"
        let decoded = SavedLogFileReader.decodeUTF8(Data(text.utf8))
        #expect(decoded.text == text)
        #expect(decoded.replacedInvalidUTF8 == false)
    }

    @Test func stripsUTF8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("中文日志\n".utf8))

        let decoded = SavedLogFileReader.decodeUTF8(data)

        #expect(decoded.text == "中文日志\n")
        #expect(decoded.replacedInvalidUTF8 == false)
    }

    @Test func replacesInvalidUTF8InsteadOfFailing() {
        let decoded = SavedLogFileReader.decodeUTF8(Data([0xE4, 0xB8]))

        #expect(decoded.text == "\u{FFFD}")
        #expect(decoded.replacedInvalidUTF8 == true)
    }

    @Test func buildsStableLineNumbersAndDropsOnlyFinalEmptyLine() {
        let lines = SavedLogFileReader.makeLines(from: "one\n\nthree\n")

        #expect(lines == [
            SavedLogLine(number: 1, text: "one"),
            SavedLogLine(number: 2, text: ""),
            SavedLogLine(number: 3, text: "three"),
        ])
    }

    @Test func managedLogFilePrefixesIncludeMihomoAndProxyCat() {
        #expect(FilePath.isManagedSavedLogFile(URL(fileURLWithPath: "/tmp/mihomo-20260511-120000.log")))
        #expect(FilePath.isManagedSavedLogFile(URL(fileURLWithPath: "/tmp/proxycat-20260511-120000.log")))
        #expect(!FilePath.isManagedSavedLogFile(URL(fileURLWithPath: "/tmp/other-20260511-120000.log")))
        #expect(!FilePath.isManagedSavedLogFile(URL(fileURLWithPath: "/tmp/proxycat-20260511-120000.txt")))
    }
}
