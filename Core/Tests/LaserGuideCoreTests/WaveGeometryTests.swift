// WaveGeometry の幾何・進行度関数テスト (DR-0011 決定 3 の仕様輪郭)。
import XCTest
@testable import LaserGuideCore

final class WaveGeometryTests: XCTestCase {

    private let unitRect = PhysicalRect(minX: 0, minY: 0, maxX: 10, maxY: 10)

    // ================================
    // distance(from:to:) — 点-矩形距離
    // ================================

    /// 矩形の内部 (境界より真に内側) にある点は距離 0。
    func testDistancePointInsideRectIsZero() {
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 5, y: 5)), 0)
    }

    /// 矩形の辺上 (境界そのもの) にある点も距離 0 (DR-0011 「点が矩形内なら 0」は境界含む契約)。
    func testDistancePointOnEdgeIsZero() {
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 0, y: 5)), 0, "左辺上")
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 10, y: 10)), 0, "右下角")
    }

    /// 矩形の軸方向 (真横) の外側にある点は、はみ出た分だけの距離になる。
    func testDistancePointOutsideAxisAligned() {
        // 右辺から x 方向に 5 離れた点、y は矩形の Y 範囲内 → 距離は x 方向のみ
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 15, y: 5)), 5, accuracy: 1e-9)
        // 上辺 (minY 側) から y 方向に 3 離れた点
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 5, y: -3)), 3, accuracy: 1e-9)
    }

    /// 矩形の斜め外側 (角の外) にある点は、はみ出た dx/dy のユークリッド距離になる
    /// (角からの最近接点は矩形の角そのもの)。
    func testDistancePointOutsideDiagonal() {
        // 右下角 (10,10) から dx=3, dy=4 はみ出た点 → 3-4-5 の直角三角形で距離 5
        XCTAssertEqual(WaveGeometry.distance(from: unitRect, to: PhysicalPoint(x: 13, y: 14)), 5, accuracy: 1e-9)
    }

    // ================================
    // maxDistanceMM(epicenter:placements:) — 全 display 4 隅の最大距離
    // ================================

    /// placements が空なら波が届く先が無い = 0。
    func testMaxDistanceMMWithNoPlacementsIsZero() {
        let epicenter = PhysicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertEqual(WaveGeometry.maxDistanceMM(epicenter: epicenter, placements: []), 0)
    }

    /// 単一 placement で、震源から最も遠い隅 (この配置では右下 (100,100) が最遠) が選ばれる。
    func testMaxDistanceMMSelectsFarthestCornerAmongSinglePlacement() {
        let epicenter = PhysicalRect(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let placement = WavePlacement(
            displayId: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
            scaleX: 1, scaleY: 1, mmRect: PhysicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100))
        // 4 隅のうち最遠は (100,100): dx=90, dy=90 → distance = sqrt(90^2+90^2)
        let expected = (90.0 * 90.0 + 90.0 * 90.0).squareRoot()
        XCTAssertEqual(WaveGeometry.maxDistanceMM(epicenter: epicenter, placements: [placement]), expected, accuracy: 1e-9)
    }

    /// 複数 placement をまたいで最遠隅を選ぶ (= 震源に近い display の隅ではなく、離れた
    /// display の隅が全体の maxDistanceMM を決めることの固定)。
    func testMaxDistanceMMSelectsFarthestCornerAcrossMultiplePlacements() {
        let epicenter = PhysicalRect(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let near = WavePlacement(
            displayId: "near", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
            scaleX: 1, scaleY: 1, mmRect: PhysicalRect(minX: 0, minY: 0, maxX: 20, maxY: 20))
        let far = WavePlacement(
            displayId: "far", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
            scaleX: 1, scaleY: 1, mmRect: PhysicalRect(minX: 1000, minY: 1000, maxX: 1100, maxY: 1100))

        // near の最遠隅 (20,20) は distance sqrt(10^2+10^2)≈14.14、far の最遠隅 (1100,1100) は
        // distance sqrt(1090^2+1090^2) と圧倒的に大きい → far 側が採用される。
        let expected = (1090.0 * 1090.0 + 1090.0 * 1090.0).squareRoot()
        XCTAssertEqual(
            WaveGeometry.maxDistanceMM(epicenter: epicenter, placements: [near, far]), expected, accuracy: 1e-6)
    }

    // ================================
    // radiusMM(progress:maxDistanceMM:bandMM:) — 進行度 → 波リング外縁半径
    // ================================

    /// p=0 (発火直後) では半径 0 (震源そのものの矩形のみ)。
    func testRadiusMMAtProgressZeroIsZero() {
        XCTAssertEqual(WaveGeometry.radiusMM(progress: 0, maxDistanceMM: 500, bandMM: 30), 0)
    }

    /// p=1 (波が最遠隅へ到達しきった時点) では半径 = maxDistanceMM + bandMM
    /// (帯幅ぶん最遠隅を追い越して消えるまでの見た目上の余白、DR-0011 決定 3)。
    func testRadiusMMAtProgressOneReachesMaxDistancePlusBand() {
        XCTAssertEqual(WaveGeometry.radiusMM(progress: 1, maxDistanceMM: 500, bandMM: 30), 530, accuracy: 1e-9)
    }

    /// 中間進行度は線形補間 (p * (maxDistanceMM + bandMM))。
    func testRadiusMMAtHalfProgressIsHalfOfMaxPlusBand() {
        XCTAssertEqual(WaveGeometry.radiusMM(progress: 0.5, maxDistanceMM: 500, bandMM: 30), 265, accuracy: 1e-9)
    }

    // ================================
    // opacity(progress:initialOpacity:) — 進行度 → 不透明度
    // ================================

    /// p=0 (発火直後) では初期不透明度そのまま。
    func testOpacityAtProgressZeroIsInitialOpacity() {
        XCTAssertEqual(WaveGeometry.opacity(progress: 0, initialOpacity: 0.5), 0.5, accuracy: 1e-9)
    }

    /// p=1 (波が消えきる時点) では不透明度 0。
    func testOpacityAtProgressOneIsZero() {
        XCTAssertEqual(WaveGeometry.opacity(progress: 1, initialOpacity: 0.5), 0, accuracy: 1e-9)
    }

    /// 中間進行度は線形減衰 (initialOpacity * (1 - p))。
    func testOpacityAtQuarterProgressIsThreeQuartersOfInitial() {
        XCTAssertEqual(WaveGeometry.opacity(progress: 0.25, initialOpacity: 0.8), 0.6, accuracy: 1e-9)
    }

    /// progress が [0,1] を超えて渡された場合 (タイマーのオーバーシュート等) はクランプされる。
    /// WaveGeometry.opacity の契約 (「p は [0,1] に clamp」) をここで明示固定する。
    func testOpacityClampsOutOfRangeProgress() {
        XCTAssertEqual(WaveGeometry.opacity(progress: 1.5, initialOpacity: 0.5), 0, accuracy: 1e-9,
                       "1 超過は 1 として扱われ不透明度 0 (負の不透明度にはならない)")
        XCTAssertEqual(WaveGeometry.opacity(progress: -0.3, initialOpacity: 0.5), 0.5, accuracy: 1e-9,
                       "負の progress は 0 として扱われ初期不透明度のまま (1 超過にはならない)")
    }
}
