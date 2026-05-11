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

@Suite struct SavedLogFileInfoTests {
    @Test func parsesMihomoFilename() {
        let url = URL(fileURLWithPath: "/tmp/mihomo-20260511-141233.log")
        let info = SavedLogFileInfo.parse(
            url: url,
            size: 1024,
            modifiedAt: .distantPast,
            isActive: false
        )
        #expect(info?.kind == .mihomo)
        #expect(info?.url == url)
        #expect(info?.size == 1024)
        #expect(info?.startedAt == makeLocalDate(year: 2026, month: 5, day: 11, hour: 14, minute: 12, second: 33))
        #expect(info?.isActive == false)
    }

    @Test func parsesProxyCatFilename() {
        let info = SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/proxycat-20260511-141233.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: true
        )
        #expect(info?.kind == .proxycat)
        #expect(info?.isActive == true)
    }

    @Test func toleratesSameSecondCollisionSuffix() {
        // Writer appends `-1`, `-2`, …, `-99` when multiple sessions
        // start in the same wall-clock second. The suffix must not
        // affect the parsed startedAt.
        let suffixed = SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/mihomo-20260511-141233-2.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        )
        let plain = SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/mihomo-20260511-141233.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        )
        #expect(suffixed?.startedAt == plain?.startedAt)
    }

    @Test func rejectsUnknownPrefix() {
        #expect(SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/other-20260511-120000.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        ) == nil)
    }

    @Test func rejectsMalformedTimestamp() {
        // Prefix matches but the date portion is garbage — the
        // pruner relies on this returning nil to skip suspect
        // files instead of letting them poison the retention sort.
        #expect(SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/mihomo-not-a-date.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        ) == nil)
    }

    @Test func rejectsTimestampWithoutTimePart() {
        // Just the date, no `-HHMMSS` time portion: `parts.count >= 2`
        // guard must reject this so the formatter doesn't silently
        // parse `20260511` against a 14-char pattern.
        #expect(SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/mihomo-20260511.log"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        ) == nil)
    }

    @Test func rejectsNonLogExtension() {
        #expect(SavedLogFileInfo.parse(
            url: URL(fileURLWithPath: "/tmp/mihomo-20260511-120000.txt"),
            size: 0,
            modifiedAt: .distantPast,
            isActive: false
        ) == nil)
    }

    @Test func kindMatchingOnlyChecksPrefixAndExtension() {
        // The cheap "is this our file" check used by isManagedSavedLogFile
        // intentionally doesn't validate the date — that's parse()'s job.
        #expect(SavedLogFileInfo.Kind.matching(filename: "mihomo-anything.log") == .mihomo)
        #expect(SavedLogFileInfo.Kind.matching(filename: "proxycat-something.log") == .proxycat)
        #expect(SavedLogFileInfo.Kind.matching(filename: "mihomo-anything.txt") == nil)
        #expect(SavedLogFileInfo.Kind.matching(filename: "random.log") == nil)
    }

    private func makeLocalDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
