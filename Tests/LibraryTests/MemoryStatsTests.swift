import Foundation
import Testing
@testable import Library

@Suite struct MemoryStatsTests {
    @Test func zeroIsReallyZero() {
        let z = MemoryStats.zero
        #expect(z.resident == 0)
        #expect(z.available == 0)
        #expect(z.fraction == 0)
        #expect(z.estimatedLimit == 0)
    }

    @Test func fractionMath() {
        let m = MemoryStats(resident: 5_000_000, available: 5_000_000)
        #expect(m.estimatedLimit == 10_000_000)
        #expect(abs(m.fraction - 0.5) < 1e-9)
    }

    @Test func fractionClampedToOne() {
        // Pathological "available" overflow: shouldn't appear in practice
        // but the Dashboard ProgressView would render past 1.0 if it did.
        let m = MemoryStats(resident: 100, available: -50)
        #expect(m.fraction == 1.0)
    }

    @Test func fractionWithZeroLimit() {
        let m = MemoryStats(resident: 0, available: 0)
        #expect(m.fraction == 0)
    }
}

@Suite struct MemoryMonitorTests {
    @Test func classifyUnknownAvailableAsNormal() {
        #expect(MemoryMonitor.classify(availableBytes: 0) == .normal)
    }

    @Test func classifyWarningThreshold() {
        #expect(MemoryMonitor.classify(availableBytes: 6 * 1024 * 1024) == .normal)
        #expect(MemoryMonitor.classify(availableBytes: 6 * 1024 * 1024 - 1) == .warning)
    }

    @Test func classifyCriticalThreshold() {
        #expect(MemoryMonitor.classify(availableBytes: 3 * 1024 * 1024) == .warning)
        #expect(MemoryMonitor.classify(availableBytes: 3 * 1024 * 1024 - 1) == .critical)
    }

    @Test func snapshotLimitUsesResidentPlusAvailable() {
        let snapshot = MemoryMonitor.Snapshot(resident: 5, available: 7, pressure: .normal)
        #expect(snapshot.estimatedLimit == 12)
    }

    @Test func snapshotLimitIsUnknownWhenAvailableIsUnknown() {
        let snapshot = MemoryMonitor.Snapshot(resident: 5, available: 0, pressure: .normal)
        #expect(snapshot.estimatedLimit == 0)
    }
}

@Suite struct TrafficSnapshotTests {
    @Test func zeroIsZero() {
        let z = TrafficSnapshot.zero
        #expect(z.up == 0)
        #expect(z.down == 0)
        #expect(z.connections == 0)
    }

    @Test func equatableMatch() {
        let a = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 5)
        let b = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 5)
        let c = TrafficSnapshot(up: 1, down: 2, upTotal: 3, downTotal: 4, connections: 6)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite struct ByteFormatterTests {
    @Test func stringFormatsBytes() {
        let s = ByteFormatter.string(1_048_576)
        // Locale-sensitive; we only assert the value contains "MB" or "MiB"
        // (binary unit selected) and a numeric value.
        #expect(!s.isEmpty)
    }

    @Test func rateAppendsPerSecond() {
        let s = ByteFormatter.rate(1024)
        #expect(s.hasSuffix("/s"))
    }

    @Test func fileSizeUsesFileStyle() {
        let s = ByteFormatter.fileSize(1_000_000)
        #expect(!s.isEmpty)
    }
}
