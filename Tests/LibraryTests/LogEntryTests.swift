import Foundation
import Testing
@testable import Library

@Suite struct LogEntryTests {
    @Test func rawLevelInitFallsBackToInfo() {
        let e = LogEntry(rawLevel: 99, message: "x")
        #expect(e.level == .info)
    }

    @Test func rawLevelInitMapsKnownLevels() {
        #expect(LogEntry(rawLevel: 0, message: "x").level == .debug)
        #expect(LogEntry(rawLevel: 1, message: "x").level == .info)
        #expect(LogEntry(rawLevel: 2, message: "x").level == .warning)
        #expect(LogEntry(rawLevel: 3, message: "x").level == .error)
        #expect(LogEntry(rawLevel: 4, message: "x").level == .silent)
    }

    @Test func eachEntryGetsUniqueID() {
        let a = LogEntry(level: .info, message: "x")
        let b = LogEntry(level: .info, message: "x")
        #expect(a.id != b.id)
    }

    @Test func logLevelOrderingMatchesFilter() {
        // The Logs view filters with `entry.level >= cutoff` and the raw
        // values must therefore go DEBUG=0 < INFO=1 < WARNING=2 < ERROR=3
        // < SILENT=4 so picking "Warning" surfaces Warning + Error. A bug
        // here would silently change which lines appear on screen.
        let ordered: [LogLevel] = [.debug, .info, .warning, .error, .silent]
        #expect(ordered.map(\.rawValue) == [0, 1, 2, 3, 4])
    }

    @Test func displayNamesAreNonEmpty() {
        for level in LogLevel.allCases {
            #expect(!level.displayName.isEmpty, "missing displayName for \(level)")
            #expect(!level.symbolName.isEmpty, "missing symbol for \(level)")
        }
    }
}
