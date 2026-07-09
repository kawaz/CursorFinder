// rate 写像 (ユーザセグメント専用) と物理投影 (OS 自動ペア専用) の混合 DPI 輪郭
// (DR-0006 決定 2、2026-07-10 コアレビュー C-1 で二写像に分離)
//
// 当初 (改訂前) はこのファイルの `testMixedDPISideBySidePreservesPhysicalProjection` が
// 「rate 写像 (50%→50%) が物理投影と一致する」ことを主張していたが、これは物理長の異なる 2 セグメント
// 間では数学的に偽 (rate 50% の位置は両セグメントで異なる物理座標になる)。C-1 レビューでこの反例が
// 指摘され、意味論を 2 つに分離した:
//   - RateMapping (ユーザセグメント専用): 物理長で正規化した比例対応。50%→50% を保証する
//   - PhysicalProjection (OS 自動ペア専用): 交点の物理座標をそのまま対向へ射影。物理直進性を保証する
// このファイルは両者それぞれの整合条件を別テストとして固定する。
import XCTest
@testable import LaserGuideCore

final class RateMappingMixedDPITests: XCTestCase {

    // 共通構成: A は 0.25 mm/px、B は 0.5 mm/px (混合 DPI)。
    //   A: 論理 [0,1920]×[0,1080] → 物理 [0,480]×[0,270] mm。右辺の物理 y レンジ = [0, 270] mm
    //   B: 論理 [1920,3840]×[0,1080]、translate.x=-480 (B の論理原点 (0,0) は物理 x=-480)
    //      → B の論理左上 (1920, 0) が物理 (480, 0) に来る。B の物理 y レンジ = [0, 540] mm
    // つまり同じ物理長 (270mm) の区間が、A では論理 270px、B では論理 540px に対応する (DPI 差)。
    private func mixedDPISideBySideDisplays() -> (a: Display, b: Display) {
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: 0, y: 0), scaleX: 0.25, scaleY: 0.25))
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: -480, y: 0), scaleX: 0.5, scaleY: 0.5))
        return (a, b)
    }

    // ==================
    // PhysicalProjection (OS 自動ペア専用): 物理座標が一致する = レーザー直線が繋がる
    // ==================

    /// A 右辺の物理 y=135mm (A の物理長 270mm の 50%) にある交点は、B 側でも同じ物理 y=135mm
    /// (B の論理 y = 135/0.5 = 270、B の物理長 540mm の 25% 相当) に射影される。
    /// rate (50%) ではなく物理座標 (135mm) がそのまま保たれることを固定する。
    func testPhysicalProjectionPreservesPhysicalCoordinateAcrossMixedDPI() {
        let (a, b) = mixedDPISideBySideDisplays()
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        let onA = segs.first { $0.displayId == "A" && $0.side == .right }!
        let onB = segs.first { $0.displayId == "B" && $0.side == .left }!

        // A の物理 (480, 135) → 論理 (1920, 540)
        let crossingLogicalOnA = a.pose.toLogical(PhysicalPoint(x: 480, y: 135))
        XCTAssertEqual(crossingLogicalOnA.y, 540, accuracy: 1e-9)

        let dst = PhysicalProjection.project(
            crossingPoint: crossingLogicalOnA,
            sourceSegment: onA, sourceDisplay: a,
            pairedSegment: onB, pairedDisplay: b
        )
        // B 側で同じ物理 y=135mm → 論理 y = 135 / 0.5 = 270 (B 側の rate は 270/540 = 25%、
        // A 側の rate 50% とは一致しない — これが RateMapping と使い分ける理由)
        XCTAssertEqual(dst.x, 1920, accuracy: 1e-9)
        XCTAssertEqual(dst.y, 270, accuracy: 1e-9)
    }

    /// 交点が対向セグメントの物理レンジ外になる場合 (Adjacency の共通区間計算では通常起きないが、
    /// カド越しの斜め交差や浮動小数誤差で越えうる安全側の分岐) は対向端へクランプする。
    /// ここでは Adjacency 経由ではなく、意図的に物理レンジが狭い paired segment を手組みして
    /// 「source 側は範囲内、paired 側の物理レンジはそれより狭い」状況を作る。
    func testPhysicalProjectionClampsToPairedSegmentPhysicalRangeWhenOutOfBounds() {
        let (a, b) = mixedDPISideBySideDisplays()
        // paired (B 側) の along レンジを [0, 200] に狭める (物理 y レンジ [0,100]mm 相当)。
        let onA = PassSegment(id: "a-r", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "b-l")
        let onB = PassSegment(id: "b-l", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 200, pairedSegmentId: "a-r")

        // A の物理 y=135mm (論理 y=540、A の物理レンジ [0,270] 内) → B の物理レンジ [0,100]mm を超える
        let crossingLogicalOnA = a.pose.toLogical(PhysicalPoint(x: 480, y: 135))
        let dst = PhysicalProjection.project(
            crossingPoint: crossingLogicalOnA,
            sourceSegment: onA, sourceDisplay: a,
            pairedSegment: onB, pairedDisplay: b
        )
        // B 側の物理レンジ上限 100mm へクランプ → 論理 y = 100 / 0.5 = 200 (= paired segment の logicalEnd)
        XCTAssertEqual(dst.y, 200, accuracy: 1e-9)
    }

    // ==================
    // RateMapping (ユーザセグメント専用): 比例位置 (rate) が一致する
    // ==================

    /// ユーザセグメントとして意図的に対応させた 2 辺 (物理長が異なる) では、rate (物理長に対する
    /// 比率) が両側で一致することを固定する。50% の位置は両側とも 50% の位置に写る
    /// (物理座標そのものは一致しない — PhysicalProjection との対比)。
    func testRateMappingPreservesProportionalPositionAcrossMixedDPI() {
        let (a, b) = mixedDPISideBySideDisplays()
        let segs = Adjacency.detectOSPassSegments([a, b])
        let onA = segs.first { $0.displayId == "A" && $0.side == .right }!
        let onB = segs.first { $0.displayId == "B" && $0.side == .left }!

        // A の物理 50% 点: y=135mm → 論理 y=540
        let crossingLogicalOnA = a.pose.toLogical(PhysicalPoint(x: 480, y: 135))
        let dst = RateMapping.warpDestination(
            crossingPoint: crossingLogicalOnA,
            sourceSegment: onA, sourceDisplay: a,
            pairedSegment: onB, pairedDisplay: b
        )
        // B の物理 50% 点: y = 540mm * 0.5 = 270mm → 論理 y = 270/0.5 = 540
        // (PhysicalProjection なら論理 y=270 になるところ、rate 写像では 540 になる)
        XCTAssertEqual(dst.x, 1920, accuracy: 1e-9)
        XCTAssertEqual(dst.y, 540, accuracy: 1e-9)
    }

    /// 等 DPI 恒等 pose では、rate 写像は論理座標の恒等に近い形になる (境界: 混合 DPI テストの baseline)。
    func testIdentityPoseSameDPI() {
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: .identity)
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080),
                        pose: .identity)
        let segs = Adjacency.detectOSPassSegments([a, b])
        let onA = segs.first { $0.displayId == "A" && $0.side == .right }!
        let onB = segs.first { $0.displayId == "B" && $0.side == .left }!

        let dst = RateMapping.warpDestination(
            crossingPoint: LogicalPoint(x: 1920, y: 540),
            sourceSegment: onA, sourceDisplay: a,
            pairedSegment: onB, pairedDisplay: b
        )
        XCTAssertEqual(dst.x, 1920, accuracy: 1e-9)
        XCTAssertEqual(dst.y, 540, accuracy: 1e-9)
    }
}
