import XCTest
@testable import Library

final class LogEntryTests: XCTestCase {
    func testRawLevelInitFallsBackToInfo() {
        let e = LogEntry(rawLevel: 99, message: "x")
        XCTAssertEqual(e.level, .info)
    }

    func testRawLevelInitMapsKnownLevels() {
        XCTAssertEqual(LogEntry(rawLevel: 0, message: "x").level, .debug)
        XCTAssertEqual(LogEntry(rawLevel: 1, message: "x").level, .info)
        XCTAssertEqual(LogEntry(rawLevel: 2, message: "x").level, .warning)
        XCTAssertEqual(LogEntry(rawLevel: 3, message: "x").level, .error)
        XCTAssertEqual(LogEntry(rawLevel: 4, message: "x").level, .silent)
    }

    func testEachEntryGetsUniqueID() {
        let a = LogEntry(level: .info, message: "x")
        let b = LogEntry(level: .info, message: "x")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testLogLevelOrderingMatchesFilter() {
        // The Logs view filters with `entry.level >= cutoff` and the raw
        // values must therefore go DEBUG=0 < INFO=1 < WARNING=2 < ERROR=3
        // < SILENT=4 so picking "Warning" surfaces Warning + Error. A bug
        // here would silently change which lines appear on screen.
        let ordered: [LogLevel] = [.debug, .info, .warning, .error, .silent]
        XCTAssertEqual(ordered.map(\.rawValue), [0, 1, 2, 3, 4])
    }

    func testDisplayNamesAreNonEmpty() {
        for level in LogLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty, "missing displayName for \(level)")
            XCTAssertFalse(level.symbolName.isEmpty, "missing symbol for \(level)")
        }
    }
}
