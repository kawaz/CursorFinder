// LatencyTracker — CGEventTap callback 内の reduce 所要時間を記録し p50/p95/p99 を集計する。
//
// 2026-07-10 実機フィードバック #5 対応 (DR-0004 の「レイテンシ計測の輪郭」実装):
//   - tap callback は main run loop 上で同期実行されるため、callback が遅いと
//     `kCGEventTapDisabledByTimeout` で黙って無効化される
//   - 実測値 (p50 / p95 / p99) を計測して dump できる仕組みを持たせ、修正効果を検証可能にする
//
// 実装契約:
//   - `record(nanoseconds:)` は tap callback 内から高頻度で呼ばれる。ロックせず配列に append
//     するだけ (main run loop 排他で十分)
//   - サンプル数上限 `capacity` を超えたら古いものから捨てる (リングバッファ相当)
//   - `snapshot()` は現時点の全サンプルをコピーして返す (dump 時に呼ぶ)
import Foundation

public final class LatencyTracker {

    public let capacity: Int
    private var samples: [UInt64] = []
    private var head: Int = 0
    private var count: Int = 0

    /// これまでに記録された総サンプル数 (リングバッファで捨てられた分も含む累計)。
    public private(set) var totalCount: UInt64 = 0

    public init(capacity: Int = 4096) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.samples.reserveCapacity(capacity)
    }

    /// tap callback から呼ぶ hot path。ns 単位の経過時間を 1 件記録する。
    public func record(nanoseconds: UInt64) {
        totalCount &+= 1
        if samples.count < capacity {
            samples.append(nanoseconds)
        } else {
            samples[head] = nanoseconds
            head = (head + 1) % capacity
        }
        count = min(count + 1, capacity)
    }

    /// p50 / p95 / p99 / max を μs で返す。サンプル 0 件時は nil。
    public func summary() -> Summary? {
        guard !samples.isEmpty else { return nil }
        var sorted = samples
        sorted.sort()
        func percentile(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
            return Double(sorted[idx]) / 1000.0
        }
        return Summary(
            sampleCount: sorted.count,
            totalCount: totalCount,
            p50Microseconds: percentile(0.50),
            p95Microseconds: percentile(0.95),
            p99Microseconds: percentile(0.99),
            maxMicroseconds: Double(sorted.last!) / 1000.0
        )
    }

    /// 集計をリセットする (dump 後などに呼ぶ運用を想定、UI では現状未接続)。
    public func reset() {
        samples.removeAll(keepingCapacity: true)
        head = 0
        count = 0
        totalCount = 0
    }

    public struct Summary: Equatable {
        public let sampleCount: Int
        public let totalCount: UInt64
        public let p50Microseconds: Double
        public let p95Microseconds: Double
        public let p99Microseconds: Double
        public let maxMicroseconds: Double

        public var oneLineDescription: String {
            String(format: "[latency] n=%d total=%llu p50=%.1fμs p95=%.1fμs p99=%.1fμs max=%.1fμs",
                sampleCount, totalCount, p50Microseconds, p95Microseconds, p99Microseconds, maxMicroseconds)
        }
    }
}
