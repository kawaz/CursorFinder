// rate 写像の整合条件 (DR-0006 決定 2: 物理長で正規化する = 混合 DPI でも物理直進性が保たれる)
//
// V3 は論理 (px) 長で正規化していたため、混合 DPI モニタ間でレーザーの直線が段付き越境になる
// バグを内包していた。DR-0006 決定 2 の "物理的に隣接するセグメントの自動ペアでは rate 写像の
// 結果が物理空間の投影と一致する" を、この輪郭テストで固定する。
import XCTest
@testable import LaserGuideCore

final class RateMappingMixedDPITests: XCTestCase {

    /// 混合 DPI 横並び: A は 0.25 mm/px、B は 0.5 mm/px。共通 y レンジは物理でずれるが、rate
    /// 写像は「物理長の 50 % 位置は物理長の 50 % 位置」に対応する = 物理空間でのレーザー直線が
    /// 連続する条件。B 側は同じ物理 y に対応する論理 y へ写る。
    func testMixedDPISideBySidePreservesPhysicalProjection() {
        // A: 論理 [0,1920]×[0,1080]、scale 0.25 mm/px、pose translate 0
        //    → 物理 [0,480]×[0,270] mm。右辺 (x=1920) の along-edge は物理 y [0, 270] mm
        // B: 論理 [1920,3840]×[0,1080]、scale 0.5 mm/px、pose translate x=480 mm (A の右端に合わせる)
        //    B の物理 y 原点は translate.y=0。B の左辺 (x=1920) 上の along-edge:
        //      物理 y = 0 + logical.y * 0.5 = [0, 540] mm ← A と物理長が違う!
        let a = Display(id: "A",
                        logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: 0, y: 0), scaleX: 0.25, scaleY: 0.25))
        // B の translate は「B の論理原点 (0,0) が物理でどこか」。B の論理左上 (1920, 0) を物理 (480, 0)
        // に合わせるには translate.x = 480 - 1920 * 0.5 = -480
        let b = Display(id: "B",
                        logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: -480, y: 0), scaleX: 0.5, scaleY: 0.5))

        // 隣接検出は論理座標だけ見ているので生成される
        let segs = Adjacency.detectOSPassSegments([a, b])
        XCTAssertEqual(segs.count, 2)
        let onA = segs.first { $0.displayId == "A" && $0.side == .right }!
        let onB = segs.first { $0.displayId == "B" && $0.side == .left }!

        // A の右辺の物理 y=135 mm (物理長 270 mm の 50 %) にある交点を渡すと、B 側では
        // B の左辺の物理 y=270 mm (物理長 540 mm の 50 %) に対応する論理点が返るはず。
        // A の物理 (480, 135) → 論理 (1920, 540)
        let crossingLogicalOnA = a.pose.toLogical(PhysicalPoint(x: 480, y: 135))
        XCTAssertEqual(crossingLogicalOnA.y, 540, accuracy: 1e-9)

        let dst = RateMapping.warpDestination(
            crossingPoint: crossingLogicalOnA,
            sourceSegment: onA, sourceDisplay: a,
            pairedSegment: onB, pairedDisplay: b
        )
        // B 側で「物理長の 50 %」= 物理 y = 270 mm、論理 y = (270 - 0) / 0.5 = 540
        // B 側の x は左辺 = 論理 x = 1920
        XCTAssertEqual(dst.x, 1920, accuracy: 1e-9)
        XCTAssertEqual(dst.y, 540, accuracy: 1e-9)
    }

    /// 等 DPI 恒等 pose では、論理 rate も物理 rate も一致するので、写像は論理座標の恒等に近い形になる。
    /// (境界: 混合 DPI テストの baseline として、恒等ケースでも rate=正しい位置に写ることを固定)
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
