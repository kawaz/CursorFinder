// 横並び 2 枚構成の隣接検出 (V3 moonbit/src/*_wbtest.mbt が固定していた仕様輪郭を y-down で再導出)
//
// 横並びは V3 でも唯一動いていたケース。ここでの期待値は V3 の写経ではなく、DR-0005 の y-down
// 規約下で「A の右辺 (maxX) が B の左辺 (minX) と接触、y 範囲の重なりが along レンジ」を再導出。
import XCTest
@testable import LaserGuideCore

final class AdjacencyHorizontalTests: XCTestCase {

    /// 同じ高さの 2 枚が横並び (A の右 = B の左) で 1 ペア (2 セグメント) が生成される。
    /// along レンジは共通の y 範囲 [0, 1080]。
    func testTwoDisplaysSideBySideSameHeight() {
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080),
                        pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2, "1 接触 = 2 セグメント (双方向)")

        let onA = segs.first { $0.displayId == "A" }
        let onB = segs.first { $0.displayId == "B" }
        XCTAssertEqual(onA?.side, .right)
        XCTAssertEqual(onB?.side, .left)
        XCTAssertEqual(onA?.logicalStart, 0)
        XCTAssertEqual(onA?.logicalEnd, 1080)
        XCTAssertEqual(onB?.logicalStart, 0)
        XCTAssertEqual(onB?.logicalEnd, 1080)
        // ペアリング相互参照
        XCTAssertEqual(onA?.pairedSegmentId, onB?.id)
        XCTAssertEqual(onB?.pairedSegmentId, onA?.id)
    }

    /// 高さが違う 2 枚 (縦オフセットあり) では along レンジは共通部分に限定される。
    /// V3 moonbit の「共通 y 範囲だけを取る」意味論の y-down 版。
    func testTwoDisplaysSideBySideDifferentHeight() {
        // A は y=[0,1080]、B は y=[300, 1500]。共通部分は [300, 1080]。
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 300, maxX: 3840, maxY: 1500),
                        pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        let onA = segs.first { $0.displayId == "A" && $0.side == .right }
        XCTAssertEqual(onA?.logicalStart, 300)
        XCTAssertEqual(onA?.logicalEnd, 1080)
    }

    /// 端が触れているだけ (y 範囲が 1 点で接する) は「接触」ではない (start < end を要求)。
    /// 「点接触」を隣接扱いすると角の斜め越境が全ペアで発火してしまう。
    func testPointContactIsNotAdjacent() {
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        // B は A の右かつ下、y 範囲が 1080 の 1 点で接する
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 1080, maxX: 3840, maxY: 2160),
                        pose: .identity)
        // A.right と B.left は x=1920 で接触するが y 共通部分は空 (max(0,1080)=1080 >= min(1080,2160)=1080)
        // A.bottom と B.top は y=1080 で接触するが x 共通部分は空 (max(0,1920)=1920 >= min(1920,3840)=1920)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 0, "1 点接触はエッジ接続として扱わない")
    }

    /// 隙間がある 2 枚 (物理的に接触していない) は隣接 0 件。BP/BB のテスト構成が前提とする
    /// 「物理的に離れた 2 枚は OS 隣接なし」を Adjacency 側でも直接固定する (m-1 minor)。
    func testGapBetweenTwoDisplaysIsNotAdjacent() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        // B は A の右に隙間 (100px) を空けて配置。maxX(A)=1920, minX(B)=2020 で接触しない。
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 2020, minY: 0, maxX: 3940, maxY: 1080), pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 0, "隙間がある 2 枚は接触辺を持たない")
    }

    /// 3 枚横並び (A-B-C 隣接) では隣接ペアが 2 組 (A-B, B-C) で計 4 セグメントになる。
    /// A-C は直接接触しない (m-1 minor: 複数枚構成での隣接検出の網羅性を固定)。
    func testThreeDisplaysSideBySideProduceFourSegments() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 3840, minY: 0, maxX: 5760, maxY: 1080), pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b, c])
        XCTAssertEqual(segs.count, 4, "A-B と B-C の 2 接触 = 4 セグメント (A-C の直接接触分は含まれない)")

        XCTAssertEqual(segs.filter { $0.displayId == "A" }.count, 1, "A は B とのみ接触")
        XCTAssertEqual(segs.filter { $0.displayId == "B" }.count, 2, "B は A・C 両方と接触")
        XCTAssertEqual(segs.filter { $0.displayId == "C" }.count, 1, "C は B とのみ接触")
    }
}
