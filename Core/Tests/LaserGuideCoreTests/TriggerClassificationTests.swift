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
