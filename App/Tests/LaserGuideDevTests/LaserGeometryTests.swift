// LaserGeometry の純関数テスト (2026-07-10 実機フィードバック #1 / #3 / #4 回帰対策)。
//
// - #1: fourCorners が自ディスプレイの 4 隅のみを返す
// - #3: taperApexPoint が standoff 距離だけポインタ手前に頂点を戻す
// - #4: viewLocal が pose を経由せず CG global を単純減算するため、継ぎ目跨ぎで
//        描画位置がスケール比で圧縮されない (旧経路との差分を明示するテストで根本原因を可視化)
import XCTest
import CoreGraphics
@testable import LaserGuideDev
import LaserGuideCore

final class LaserGeometryTests: XCTestCase {

    // ================================================================
    // #4: 境界跨ぎ時の描画位置連続性 — 根本原因の再現テスト
    // ================================================================

    /// 実機構成 (findings/2026-07-09-macos-display-api-verification.md §4):
    ///   内蔵 Retina: bounds 0..2056 × 0..1329, mm 344.7 × 222.8, scale ≒ 0.1677 mm/px
    ///   LG ULTRAGEAR+: bounds -258..3182 × -1440..0, mm 1052.7 × 440.7, scale ≒ 0.306 mm/px
    /// 両者は継ぎ目 y=0 で上下に隣接している。
    ///
    /// 実機報告 (2026-07-10 #4):
    ///   継ぎ目中央付近 (x ∈ [0, 2056]) を通って移動すると、LG overlay の描画上で
    ///   ポインタ描画位置が実際の移動量よりはるかに微量な距離だけ「境界付近で
    ///   左右にジリジリ」動く症状が観測された。
    ///
    /// 期待挙動 (fix 後): CG global 論理座標で 1px 実移動 → view local でも 1px 描画変化。
    /// 修正前挙動 (旧経路): mouseDisplay pose (built-in) → selfDisplay pose (LG) の
    /// 経路で mm 単位が異なるため、1px の実移動が 0.55px 程度に圧縮される (下記参照)。
    func testTargetIsContinuousAcrossSeamOnLGOverlay_FixesBug4() {
        let lgBounds = LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0)

        // 継ぎ目 y=0 を 2px 跨ぐ 2 点 (built-in 側 y=+1、LG 側 y=-1)
        let onBuiltIn = LogicalPoint(x: 100, y: 1)
        let onLG = LogicalPoint(x: 100, y: -1)

        // 修正後 (現行 viewLocal): CG global を単純減算するため continuous
        let vlBuiltIn = LaserGeometry.viewLocal(onBuiltIn, in: lgBounds)
        let vlLG = LaserGeometry.viewLocal(onLG, in: lgBounds)
        XCTAssertEqual(vlBuiltIn.x, vlLG.x, accuracy: 1e-9,
            "CG global の 100px 位置は継ぎ目跨ぎで view local x が一致する")
        XCTAssertEqual(vlBuiltIn.y - vlLG.y, 2.0, accuracy: 1e-9,
            "2px の実移動が 2px の描画変化として反映される (連続、スケール圧縮なし)")

        // 参考: 旧経路 (mouseDisplay.pose.toPhysical → selfDisplay.pose.toLogical) を
        // 同じ入力で計算し、圧縮量を明示する。built-in mm/px = 0.1677、LG mm/px = 0.306。
        // built-in 側 y=+1 の見かけ:
        //   physical_y = 1 * 0.1677 = 0.1677 mm (built-in mm frame)
        //   これを LG mm frame として扱い、LG pose で logical に戻す:
        //   logical_on_LG_y = 0.1677 / 0.306 ≒ 0.548
        //   viewLocal.y = 0.548 - (-1440) ≒ 1440.548
        // LG 側 y=-1 の見かけ (mouseDisplay も selfDisplay も LG なので正確):
        //   viewLocal.y = -1 - (-1440) = 1439
        // 差 = 1.548 (< 2)。実移動 2 に対し ~77% しか反映されず、mouseDisplay が
        // built-in ↔ LG で切り替わる度にジャンプ幅も変わる → ジリジリして見える。
        let scaleBuiltIn = 344.7 / 2056.0
        let scaleLG = 1052.7 / 3440.0
        let oldViewLocalYBuiltInSide = (onBuiltIn.y * scaleBuiltIn) / scaleLG - lgBounds.minY
        let oldViewLocalYLGSide = (onLG.y * scaleLG) / scaleLG - lgBounds.minY
        let oldJump = oldViewLocalYBuiltInSide - oldViewLocalYLGSide
        XCTAssertLessThan(oldJump, 1.7,
            "旧経路は 2px 実移動を 1.7px 未満に圧縮する (境界ジリジリの根本原因)")
    }

    // ================================================================
    // #1: 自ディスプレイの 4 角のみ
    // ================================================================

    func testFourCornersReturnsExactlyFourCornersOfBounds() {
        let r = LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0)
        let cs = LaserGeometry.fourCorners(of: r)
        XCTAssertEqual(cs.count, 4)
        XCTAssertTrue(cs.contains(LogicalPoint(x: -258, y: -1440)))
        XCTAssertTrue(cs.contains(LogicalPoint(x: 3182, y: -1440)))
        XCTAssertTrue(cs.contains(LogicalPoint(x: -258, y: 0)))
        XCTAssertTrue(cs.contains(LogicalPoint(x: 3182, y: 0)))
    }

    // ================================================================
    // #3: standoff テーパー
    // ================================================================

    func testTaperApexIsPulledBackByStandoffAlongCornerToTarget() {
        // corner (0,0) → target (100, 0)、standoff 20 → apex は (80, 0)
        let apex = LaserGeometry.taperApexPoint(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), standoff: 20)
        XCTAssertNotNil(apex)
        XCTAssertEqual(apex!.x, 80, accuracy: 1e-9)
        XCTAssertEqual(apex!.y, 0, accuracy: 1e-9)
    }

    func testTaperApexPreservesDirectionOnDiagonal() {
        // corner (0,0) → target (30, 40) (距離 50)、standoff 10 → apex 距離 40
        let apex = LaserGeometry.taperApexPoint(
            from: .zero, to: CGPoint(x: 30, y: 40), standoff: 10)
        XCTAssertNotNil(apex)
        // apex は (30, 40) の 80% の位置 → (24, 32)
        XCTAssertEqual(apex!.x, 24, accuracy: 1e-9)
        XCTAssertEqual(apex!.y, 32, accuracy: 1e-9)
    }

    func testTaperApexNilWhenTargetTooCloseToCorner() {
        // 距離 5、standoff 20 → 描画不能
        XCTAssertNil(LaserGeometry.taperApexPoint(
            from: .zero, to: CGPoint(x: 5, y: 0), standoff: 20))
        // 距離 = standoff の境界も nil (最小長 1 を加えているため)
        XCTAssertNil(LaserGeometry.taperApexPoint(
            from: .zero, to: CGPoint(x: 20, y: 0), standoff: 20))
    }

    // ================================================================
    // #3 第 2 ラウンド: standoff の割合ベース化 (2026-07-10)
    //
    // 固定 40px から「角→ポインタ距離の 10% (defaultStandoffRatio)」+ min/max px クランプへ変更。
    // taperApexPoint 自体 (standoff を受け取って頂点を戻す幾何計算) は変更しないため上のテストは
    // そのまま有効。ここでは「standoff をどう決めるか」(LaserGeometry.standoffDistance) を検証する。
    // ================================================================

    /// 通常域: 距離 1000px の 10% = 100px はクランプ範囲 (8...200) 内なので、そのまま採用される。
    func testStandoffDistanceUsesRatioWhenWithinClampRange() {
        let standoff = LaserGeometry.standoffDistance(cornerToTargetDistance: 1000)
        XCTAssertEqual(standoff, 100, accuracy: 1e-9, "1000px の 10% = 100px、min/max の間なのでそのまま")
    }

    /// 短いレーザー: 距離 30px の 10% = 3px は下限 (minStandoffDistance=8) を下回るため、8px にクランプされる。
    /// (min クランプが無いと極端に短いレーザーで頂点が角に潰れて見た目が破綻する)
    func testStandoffDistanceClampsToMinimumForShortLaser() {
        let standoff = LaserGeometry.standoffDistance(cornerToTargetDistance: 30)
        XCTAssertEqual(standoff, LaserGeometry.minStandoffDistance, accuracy: 1e-9, "3px は下限 8px 未満なので min にクランプ")
        XCTAssertEqual(standoff, 8, accuracy: 1e-9)
    }

    /// 長いレーザー: 距離 5000px の 10% = 500px は上限 (maxStandoffDistance=200) を超えるため、200px にクランプされる。
    /// (max クランプが無いと極端に長いレーザーで standoff が過大になり、ポインタから離れすぎて見える)
    func testStandoffDistanceClampsToMaximumForLongLaser() {
        let standoff = LaserGeometry.standoffDistance(cornerToTargetDistance: 5000)
        XCTAssertEqual(standoff, LaserGeometry.maxStandoffDistance, accuracy: 1e-9, "500px は上限 200px 超なので max にクランプ")
        XCTAssertEqual(standoff, 200, accuracy: 1e-9)
    }

    /// standoffDistance が返した値を taperApexPoint にそのまま渡すと、既存の幾何計算 (このファイル
    /// 冒頭のテスト群) と同じ意味論で頂点が引かれることを end-to-end で固定する。
    func testStandoffDistanceComposesWithTaperApexPoint() {
        // corner (0,0) → target (1000, 0)、距離 1000 → standoff 100 (通常域) → apex は 90% 位置 (900,0)
        let corner = CGPoint.zero
        let target = CGPoint(x: 1000, y: 0)
        let standoff = LaserGeometry.standoffDistance(cornerToTargetDistance: 1000)
        let apex = LaserGeometry.taperApexPoint(from: corner, to: target, standoff: standoff)
        XCTAssertNotNil(apex)
        XCTAssertEqual(apex!.x, 900, accuracy: 1e-9)
        XCTAssertEqual(apex!.y, 0, accuracy: 1e-9)
    }

    // ================================================================
    // viewLocal 基本挙動
    // ================================================================

    func testViewLocalSubtractsBoundsOrigin() {
        let b = LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0)
        XCTAssertEqual(LaserGeometry.viewLocal(LogicalPoint(x: -258, y: -1440), in: b), .zero)
        let p = LaserGeometry.viewLocal(LogicalPoint(x: 100, y: -1000), in: b)
        XCTAssertEqual(p.x, 358, accuracy: 1e-9)
        XCTAssertEqual(p.y, 440, accuracy: 1e-9)
    }
}
