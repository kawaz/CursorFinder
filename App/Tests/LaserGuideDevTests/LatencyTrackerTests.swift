// LatencyTracker の純関数テスト (percentile 計算 / リングバッファ)。
import XCTest
@testable import LaserGuideDev

final class LatencyTrackerTests: XCTestCase {

    func testEmptySummaryIsNil() {
        let t = LatencyTracker(capacity: 10)
        XCTAssertNil(t.summary())
    }

    func testPercentilesForKnownDistribution() {
        // 1..100 ns を 1 件ずつ入れる → p50 = 50ns = 0.05μs, p95 = 95ns, p99 = 99ns, max = 100ns
        let t = LatencyTracker(capacity: 100)
        for v in 1...100 { t.record(nanoseconds: UInt64(v)) }
        let s = t.summary()!
        XCTAssertEqual(s.sampleCount, 100)
        XCTAssertEqual(s.totalCount, 100)
        XCTAssertEqual(s.p50Microseconds, 0.050, accuracy: 1e-9)
        XCTAssertEqual(s.p95Microseconds, 0.095, accuracy: 1e-9)
        XCTAssertEqual(s.p99Microseconds, 0.099, accuracy: 1e-9)
        XCTAssertEqual(s.maxMicroseconds, 0.100, accuracy: 1e-9)
    }

    func testRingBufferDropsOldestBeyondCapacity() {
        let t = LatencyTracker(capacity: 3)
        // 4 件入れると 1 件目 (10) が捨てられ、[20, 30, 40] が残る
        t.record(nanoseconds: 10)
        t.record(nanoseconds: 20)
        t.record(nanoseconds: 30)
        t.record(nanoseconds: 40)
        let s = t.summary()!
        XCTAssertEqual(s.sampleCount, 3)
        XCTAssertEqual(s.totalCount, 4, "totalCount は捨てられた分も累計する")
        XCTAssertEqual(s.maxMicroseconds, 0.040, accuracy: 1e-9)
        // p50 (index 1) = 30ns
        XCTAssertEqual(s.p50Microseconds, 0.030, accuracy: 1e-9)
    }

    func testResetClearsSamplesAndCounter() {
        let t = LatencyTracker(capacity: 10)
        for v in 1...5 { t.record(nanoseconds: UInt64(v)) }
        XCTAssertNotNil(t.summary())
        t.reset()
        XCTAssertNil(t.summary())
        XCTAssertEqual(t.totalCount, 0)
    }
}
