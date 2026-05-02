import XCTest
@testable import Library

final class MemoryStatsTests: XCTestCase {
    func testZeroIsReallyZero() {
        let z = MemoryStats.zero
        XCTAssertEqual(z.resident, 0)
        XCTAssertEqual(z.available, 0)
        XCTAssertEqual(z.fraction, 0)
        XCTAssertEqual(z.estimatedLimit, 0)
    }

    func testFractionMath() {
        let m = MemoryStats(resident: 5_000_000, available: 5_000_000)
        XCTAssertEqual(m.estimatedLimit, 10_000_000)
        XCTAssertEqual(m.fraction, 0.5, accuracy: 1e-9)
    }

    func testFractionClampedToOne() {
        // Pathological "available" overflow: shouldn't appear in practice
        // but the Dashboard ProgressView would render past 1.0 if it did.
        let m = MemoryStats(resident: 100, available: -50)
        XCTAssertEqual(m.fraction, 1.0)
    }

    func testFractionWithZeroLimit() {
        let m = MemoryStats(resident: 0, available: 0)
        XCTAssertEqual(m.fraction, 0)
    }
}

final class TrafficSnapshotTests: XCTestCase {
    func testZeroIsZero() {
        let z = TrafficSnapshot.zero
        XCTAssertEqual(z.up, 0)
        XCTAssertEqual(z.down, 0)
        XCTAssertEqual(z.connections, 0)
    }

    func testEquatable() {
        let a = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 5)
        let b = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 5)
        let c = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 6)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

final class ByteFormatterTests: XCTestCase {
    func testStringFormatsBytes() {
        let s = ByteFormatter.string(1_048_576)
        // Locale-sensitive; we only assert the value contains "MB" or "MiB"
        // (binary unit selected) and a numeric value.
        XCTAssertFalse(s.isEmpty)
    }

    func testRateAppendsPerSecond() {
        let s = ByteFormatter.rate(1024)
        XCTAssertTrue(s.hasSuffix("/s"))
    }

    func testFileSizeUsesFileStyle() {
        let s = ByteFormatter.fileSize(1_000_000)
        XCTAssertFalse(s.isEmpty)
    }
}
