// トリガー分類 (DR-0004 fast path 3 分類 + DR-0006 BX の入力契約)
//
// - interior: 同一モニタ内
// - PX: 所属モニタ id が変化
// - BX: current がエッジ上 + delta 符号が外向き
// - エッジ上を「滑る」だけの動き (delta が接線方向) は BX にしない
// - 角の斜め越境 (top と right が同時候補) は優先度 top→bottom→left→right で決定的
import XCTest
@testable import LaserGuideCore

final class TriggerClassificationTests: XCTestCase {

    // 便利: 2 枚横並び基本構成
    private func twoDisplays() -> [Display] {
        [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
    }

    /// 同一モニタ内の移動は interior
    func testInteriorSameDisplay() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 100, y: 100), "A"),
            current: (LogicalPoint(x: 200, y: 100), "A"),
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        XCTAssertEqual(m, .interior)
    }

    /// prev と current が別モニタなら PX で crossing 線分を返す
    func testPXOnDisplayChange() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1900, y: 500), "A"),
            current: (LogicalPoint(x: 1940, y: 500), "B"),
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        if case let .px(line, prevId, curId) = m {
            XCTAssertEqual(prevId, "A")
            XCTAssertEqual(curId, "B")
            XCTAssertEqual(line.from, LogicalPoint(x: 1900, y: 500))
            XCTAssertEqual(line.to, LogicalPoint(x: 1940, y: 500))
        } else {
            XCTFail("expected .px, got \(m)")
        }
    }

    /// 右辺にクランプされていて delta 符号も外向き (+x) なら BX(right)。
    /// OS が仮想エッジで止めたことを毎イベント連続で伝える (BX は連続発火する前提)。
    func testBXOnRightEdge() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1900, y: 500), "A"),
            current: (LogicalPoint(x: 1920, y: 500), "A"),
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        XCTAssertEqual(m, .bx(displayId: "A", side: .right))
    }

    /// エッジ上を「滑る」動き (delta が接線方向、外向き成分なし) は BX にしない = interior。
    /// これを BX にしてしまうと、端に沿ってスクロールバーへ移動しただけで毎回ワープが起動する。
    func testSlidingAlongEdgeIsNotBX() {
        let ds = twoDisplays()
        // 右辺上を上下に滑る (delta.dx == 0, delta.dy = 1)
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1920, y: 400), "A"),
            current: (LogicalPoint(x: 1920, y: 500), "A"),
            deltaSign: (dx: 0, dy: 1),
            displays: ds)
        XCTAssertEqual(m, .interior)
    }

    /// prev.displayId が nil (初回イベント等) の時は PX を出さず interior 扱い。BX は評価。
    /// これがないと初回イベントで誤 PX が出て履歴も未整備な状態で slow path が走る。
    func testNilPrevDisplayIdDoesNotTriggerPX() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 100, y: 100), nil),
            current: (LogicalPoint(x: 200, y: 100), "A"),
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        XCTAssertEqual(m, .interior)
    }

    /// 角で 2 側の外向き delta が同時候補になる場合、優先度リスト top→bottom→left→right で決定的。
    /// (右下角 (1920, 1080) で delta が (+x, +y) → bottom と right が候補、bottom が優先)
    func testCornerPriorityBottomBeatsRight() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1919, y: 1079), "A"),
            current: (LogicalPoint(x: 1920, y: 1080), "A"),
            deltaSign: (dx: 1, dy: 1),
            displays: ds)
        XCTAssertEqual(m, .bx(displayId: "A", side: .bottom))
    }

    /// 実機観測: max 側エッジは境界値 − 0.02 px の位置にクランプされる (docs/findings/
    /// 2026-07-09-macos-display-api-verification.md §4)。== 比較では取り逃すので ε 近傍判定必須。
    /// このケースは right 辺 (maxX=1920) で observedX=1919.98 → BX と判定されるべき。
    func testBXOnMaxSideEdgeWithOSClampOffset() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1900, y: 500), "A"),
            current: (LogicalPoint(x: 1919.98, y: 500), "A"),  // 実機 max クランプ位置
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        XCTAssertEqual(m, .bx(displayId: "A", side: .right))
    }

    /// min 側エッジは実機で境界値ちょうど (0.00) にクランプ。ε 近傍が広すぎて誤検出しないことを固定。
    /// (top 辺は y=0.00、delta.dy=-1 で BX)
    func testBXOnMinSideEdgeAtExactCoord() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 500, y: 20), "A"),
            current: (LogicalPoint(x: 500, y: 0.0), "A"),
            deltaSign: (dx: 0, dy: -1),
            displays: ds)
        XCTAssertEqual(m, .bx(displayId: "A", side: .top))
    }

    /// ε より遠い位置は BX にしない (誤検出防止)。ε=0.1 のデフォルトで 0.5 px 内側は interior。
    func testNotBXWhenFurtherThanEpsilonFromEdge() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1900, y: 500), "A"),
            current: (LogicalPoint(x: 1919.5, y: 500), "A"),  // -0.5 px、ε=0.1 の外側
            deltaSign: (dx: 1, dy: 0),
            displays: ds)
        XCTAssertEqual(m, .interior)
    }

    /// edgeEpsilon 引数を大きくすると内側の点も BX 扱いになる (API 挙動の説明的固定)。
    func testEdgeEpsilonIsConfigurable() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1900, y: 500), "A"),
            current: (LogicalPoint(x: 1919.0, y: 500), "A"),  // -1.0 px 内側
            deltaSign: (dx: 1, dy: 0),
            displays: ds,
            edgeEpsilon: 2.0)
        XCTAssertEqual(m, .bx(displayId: "A", side: .right))
    }

    /// 左上角 (0,0) で delta (-x, -y) → top と left が候補、top が優先。
    func testCornerPriorityTopBeatsLeft() {
        let ds = twoDisplays()
        let m = Trigger.classify(
            prev: (LogicalPoint(x: 1, y: 1), "A"),
            current: (LogicalPoint(x: 0, y: 0), "A"),
            deltaSign: (dx: -1, dy: -1),
            displays: ds)
        XCTAssertEqual(m, .bx(displayId: "A", side: .top))
    }
}
