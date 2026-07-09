// 境界値ケース (task 仕様 (e): 角の斜め越境、サイズゼロ区間、エッジ上滑り)
//
// Trigger 側の corner priority と sliding は TriggerClassificationTests でカバー済。
// ここでは Judgement 側の境界と RateMapping の縮退ケースを扱う。
import XCTest
@testable import LaserGuideCore

final class BoundaryTests: XCTestCase {

    /// PB クランプ座標が端点 (共通レンジの端) に来たケース。noCrossing にせず PB として扱う。
    /// 「レンジ端点 == 越境しなかった」と解釈すると、上下辺ぎりぎりで越境した瞬間 PB を取り逃す。
    func testPBAtSegmentEndpointIsStillPB() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity)
        let tables = WarpTables(displays: [a, b], userSegments: [])  // user は空 → PB 期待
        let line = LineSegment(from: LogicalPoint(x: 1900, y: 0), to: LogicalPoint(x: 1940, y: 0))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        if case .pb = j { /* OK */ } else { XCTFail("expected .pb, got \(j)") }
    }

    /// 論理長ゼロ (start == end) セグメントの rate 写像は 0 で扱う (割り算縮退を回避)。
    /// 通常の隣接検出ではゼロ長は生成されないが、ユーザセグメントで発生した時に判定を落とさない。
    func testZeroLengthSegmentRateMappingReturnsStart() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity)
        let src = PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 500, logicalEnd: 500, pairedSegmentId: "u-B")
        let dst = PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 300, logicalEnd: 700, pairedSegmentId: "u-A")
        let result = RateMapping.warpDestination(
            crossingPoint: LogicalPoint(x: 1920, y: 500),
            sourceSegment: src, sourceDisplay: a,
            pairedSegment: dst, pairedDisplay: b
        )
        // rate = 0 相当 → paired の start (y=300)
        XCTAssertEqual(result.x, 1920, accuracy: 1e-9)
        XCTAssertEqual(result.y, 300, accuracy: 1e-9)
    }

    /// 論理長が端で逆転している (start > end 「捻れ」) セグメントでも rate 写像が使える。
    /// V3 で「捻れ対応」として型は許容していたが Swift 側の挙動も揃える。
    func testReversedRangeStillMaps() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity)
        // A 側 [0→1080]、B 側 [1080→0] (捻れ)
        let src = PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-B")
        let dst = PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 1080, logicalEnd: 0, pairedSegmentId: "u-A")
        // rate=0.25 の点 (A 側 y=270) は捻れた B 側では y = 1080 - 270 = 810
        let result = RateMapping.warpDestination(
            crossingPoint: LogicalPoint(x: 1920, y: 270),
            sourceSegment: src, sourceDisplay: a,
            pairedSegment: dst, pairedDisplay: b
        )
        XCTAssertEqual(result.y, 810, accuracy: 1e-9)
    }
}
