import Foundation
import Testing
@testable import Library

@Suite struct LogEntryTests {
    @Test func rawLevelInitFallsBackToInfo() {
        let e = LogEntry(rawLevel: 99, message: "x", timestampNs: 0)
        #expect(e.level == .info)
    }

    @Test func rawLevelInitMapsKnownLevels() {
        #expect(LogEntry(rawLevel: 0, message: "x", timestampNs: 0).level == .debug)
        #expect(LogEntry(rawLevel: 1, message: "x", timestampNs: 0).level == .info)
        #expect(LogEntry(rawLevel: 2, message: "x", timestampNs: 0).level == .warning)
        #expect(LogEntry(rawLevel: 3, message: "x", timestampNs: 0).level == .error)
        #expect(LogEntry(rawLevel: 4, message: "x", timestampNs: 0).level == .silent)
    }

    @Test func timestampNsTakesPrecedenceOverWallClock() {
        // 2026-05-11 14:12:33 UTC = 1778566353 seconds.
        let ns: Int64 = 1_778_566_353_000_000_000
        let e = LogEntry(rawLevel: 1, message: "x", timestampNs: ns)
        #expect(e.timestamp.timeIntervalSince1970 == 1_778_566_353)
    }

    @Test func timestampNsFallsBackToNowWhenZeroOrNegative() {
        let before = Date()
        let entry = LogEntry(rawLevel: 1, message: "x", timestampNs: 0)
        let after = Date()
        #expect(entry.timestamp >= before)
        #expect(entry.timestamp <= after)
        // Also negative — same fallback (older Go cores never sent it).
        let negative = LogEntry(rawLevel: 1, message: "x", timestampNs: -1)
        #expect(negative.timestamp >= entry.timestamp)
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
