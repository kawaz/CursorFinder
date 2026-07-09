// 上下隣接 2 枚構成 (V3 で 0 件だった軸、DR-0005 検証輪郭 (a) の必須項目)
//
// y-down 規約: 「下のモニタ = y が大きい」。V3 の init.mbt は y-up 前提で Top/Bottom を割り当てて
// いたためこのケースが全滅していた。ここで y-down での正しい仕様を固定する。
import XCTest
@testable import LaserGuideCore

final class AdjacencyVerticalTests: XCTestCase {

    /// A が上 (minY=0)、B が下 (minY=1080)。A.bottom (maxY) が B.top (minY) と接触する。
    /// y-down なので「下 = maxY」「上 = minY」、V3 y-up 実装と Top/Bottom が真逆になる。
    func testTopAndBottomDisplays() {
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 0, minY: 1080, maxX: 1920, maxY: 2160),
                        pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2)

        let onA = segs.first { $0.displayId == "A" }
        let onB = segs.first { $0.displayId == "B" }
        // A は上のモニタなので A の下辺 (maxY 側 = .bottom) が接触辺
        XCTAssertEqual(onA?.side, .bottom, "y-down 規約: 上のモニタの接触辺は .bottom (= maxY)")
        // B は下のモニタなので B の上辺 (minY 側 = .top) が接触辺
        XCTAssertEqual(onB?.side, .top, "y-down 規約: 下のモニタの接触辺は .top (= minY)")
        // along レンジ = 共通 x 範囲
        XCTAssertEqual(onA?.logicalStart, 0)
        XCTAssertEqual(onA?.logicalEnd, 1920)
    }

    /// 左右にオフセットして上下配置した場合の along レンジは共通 x 範囲に限定される。
    func testTopBottomOffsetHorizontally() {
        // 上 A x=[0,1920]、下 B x=[500,2500]。共通は [500, 1920]。
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 500, minY: 1080, maxX: 2500, maxY: 2160),
                        pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        let onA = segs.first { $0.displayId == "A" && $0.side == .bottom }
        XCTAssertEqual(onA?.logicalStart, 500)
        XCTAssertEqual(onA?.logicalEnd, 1920)
    }

    /// 逆順 (B が上、A が下) で入力しても Top/Bottom 割り当ては物理位置基準で正しくつく。
    /// 隣接検出は入力順に依存しない (id ソートで決定的順序化しているが、side 判定自体は物理関係で決まる)。
    func testOrderIndependence() {
        let up = Display(id: "up",
                         logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                         pose: .identity)
        let down = Display(id: "down",
                           logicalBounds: LogicalRect(minX: 0, minY: 1080, maxX: 1920, maxY: 2160),
                           pose: .identity)
        let s1 = Adjacency.detectOSPassSegments([up, down])
        let s2 = Adjacency.detectOSPassSegments([down, up])
        // 「上のモニタは .bottom 辺、下のモニタは .top 辺」が入力順によらず一定
        XCTAssertEqual(s1.first(where: { $0.displayId == "up" })?.side, .bottom)
        XCTAssertEqual(s2.first(where: { $0.displayId == "up" })?.side, .bottom)
    }
}
