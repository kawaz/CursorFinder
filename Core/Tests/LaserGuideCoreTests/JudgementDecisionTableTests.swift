// PP/PB/BP/BB 4 状態のデシジョンテーブル (DR-0006: os/user 2 集合の所属差分で導出する)
//
// PX (OS 通過) 経路:
//   os あり + user あり → PP (何もしない)
//   os あり + user なし → PB (クランプ差し戻し = 交点で止める)
// BX (OS ブロック) 経路:
//   user あり → BP (paired へワープ)
//   user なし → BB (何もしない)
//
// V3 では PB を表現できないのが Critical 判定だった (virtual_edges は通過可能な接続しか持てず
// force_block の実行時変換でしか PB が発生しなかった)。ここでは 2 集合の差分で 4 状態すべてを
// 独立に構成し、判定関数がその通り分岐することを固定する。
import XCTest
@testable import LaserGuideCore

final class JudgementDecisionTableTests: XCTestCase {

    // 2 枚横並び基本構成 (A 右辺 = B 左辺、共通 y [0,1080])
    private func makeDisplays() -> [Display] {
        [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
    }

    // OS セグメント上と同じ範囲を丸ごと covers するユーザ側セグメントペア
    private func userSegmentsFullOverlap() -> [PassSegment] {
        [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
    }

    // ==================
    // PX 経路
    // ==================

    /// PP: A→B に横切る線分。os も user もこの along 位置をカバー → 何もしない。
    func testPP_OSAndUserBothPresent() {
        let tables = WarpTables(displays: makeDisplays(), userSegments: userSegmentsFullOverlap())
        let line = LineSegment(from: LogicalPoint(x: 1900, y: 500), to: LogicalPoint(x: 1940, y: 500))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        XCTAssertEqual(j, .pp)
    }

    /// PB: os は接触エッジ全長 [0,1080] を持つが、user は上半分 [0,300] しかカバーしない。
    ///     y=500 で越境しようとしたので user 側は空 = PB。交点座標 (1920, 500) にクランプ。
    func testPB_UserAbsentAtCrossing() {
        // user は上端 [0,300] のみ
        let users: [PassSegment] = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-A"),
        ]
        let tables = WarpTables(displays: makeDisplays(), userSegments: users)
        let line = LineSegment(from: LogicalPoint(x: 1900, y: 500), to: LogicalPoint(x: 1940, y: 500))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        if case let .pb(clamp) = j {
            XCTAssertEqual(clamp, LogicalPoint(x: 1920, y: 500))
        } else {
            XCTFail("expected .pb, got \(j)")
        }
    }

    /// noCrossing: 線分が該当 OS エッジ (source display の隣接辺) と交わらない (interior 内での誤呼び出し等)。
    /// 通常起きないが安全側の分岐として仕様化。
    func testPX_NoCrossingWhenLineDoesNotIntersectAdjacencyEdge() {
        let tables = WarpTables(displays: makeDisplays(), userSegments: userSegmentsFullOverlap())
        // A 内で完結する線分 (x=1920 に届かない)
        let line = LineSegment(from: LogicalPoint(x: 100, y: 100), to: LogicalPoint(x: 200, y: 200))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        XCTAssertEqual(j, .noCrossing)
    }

    // ==================
    // BX 経路
    // ==================

    /// BP: 物理的に隣接していない 2 枚 (OS はブロック) に対しユーザが仮想接続を貼っている場合。
    ///     BX で当該 along を含むユーザセグメントが存在 → paired display の対応点へワープ。
    func testBP_UserOnlyNoOSAdjacency() {
        // OS 隣接なし: A と C は物理的に離れている
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        // ユーザは A.right を C.left に仮想接続
        let users = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        let tables = WarpTables(displays: [a, c], userSegments: users)
        // OS は A の右で止めている (BX)、位置は y=500
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 1920, y: 500),
            displayId: "A", side: .right,
            tables: tables,
            inwardInsetMillimeters: 0)  // inset 0 で座標を明示比較
        if case let .pass(dst) = outcome {
            // C の左辺 (x=5000)、y=500
            XCTAssertEqual(dst.x, 5000, accuracy: 1e-9)
            XCTAssertEqual(dst.y, 500, accuracy: 1e-9)
        } else {
            XCTFail("expected .pass, got \(outcome)")
        }
    }

    /// BB: OS もユーザも接続なし → BX しても何もしない。
    func testBB_NoUserSegmentNoWarp() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let tables = WarpTables(displays: [a], userSegments: [])
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 1920, y: 500),
            displayId: "A", side: .right,
            tables: tables)
        XCTAssertEqual(outcome, .block)
    }

    /// BP に inset (paired 側内側への微小ずらし) を適用すると、着地点はエッジより内側になる。
    /// これがないと着地直後の座標がまだエッジ上のままで BX が即再発する。
    func testBP_InwardInsetPushesWarpDestinationInsidePairedDisplay() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        // C の scaleX = 0.5 mm/px、pose translate.x = 0 → C の論理原点 x=5000 は物理 x=2500 mm
        // inset 1 mm を論理 px に換算: 1 / 0.5 = 2 px 内側 (paired 側は left なので +x へずらす)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: 0, y: 0), scaleX: 0.5, scaleY: 0.5))
        let users = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        let tables = WarpTables(displays: [a, c], userSegments: users)
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 1920, y: 500),
            displayId: "A", side: .right,
            tables: tables,
            inwardInsetMillimeters: 1.0)
        if case let .pass(dst) = outcome {
            XCTAssertEqual(dst.x, 5002, accuracy: 1e-9, "1 mm を scaleX=0.5 で割ると 2 px 内側")
        } else {
            XCTFail("expected .pass, got \(outcome)")
        }
    }
}
