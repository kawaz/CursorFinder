// WaveLayout.placements の「隣接物理レイアウト構築」テスト (DR-0011 決定 2 の仕様輪郭)。
//
// 各テストは「どの接触パターンで、mm 空間のどこに置かれるべきか」を手計算した期待値で固定する。
// 期待値の導出はコメントに残す (= このテストだけで実装をゼロから再現できるように)。
import XCTest
@testable import LaserGuideCore

final class WaveLayoutTests: XCTestCase {

    /// 浮動小数の丸め誤差を許容する比較 (mm 単位の手計算値と 1e-6mm 未満の差は同一視する)。
    private func assertMMPointEqual(
        _ actual: PhysicalPoint, _ expected: PhysicalPoint, accuracy: Double = 1e-6,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    }

    private func assertMMRectEqual(
        _ actual: PhysicalRect, _ expected: PhysicalRect, accuracy: Double = 1e-6,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "\(message) minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "\(message) minY", file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, "\(message) maxX", file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, "\(message) maxY", file: file, line: line)
    }

    // ================================
    // (a) 実機構成の再現: 内蔵 + LG (docs/findings/2026-07-09-macos-display-api-verification.md
    //     の実測ジオメトリを土台に、task 指示で与えられた scale 値を使う)
    // ================================
    //
    // 内蔵: logicalBounds (0,0)-(2056,1329), scale (0.1338, 0.1341)
    // LG:   logicalBounds (-517,-1440)-(2923,0) (= origin(-517,-1440) + size 3440x1440),
    //       scale (0.2314, 0.2319)
    // LG.maxY(=0) == 内蔵.minY(=0) で LG が内蔵の「上」に接触 (y-down: minY 側が上)。
    // 直交方向 (X) の overlap は [max(0,-517), min(2056,2923)] = [0,2056]、中点 xc=1028。
    //
    // 期待値 (Python で事前計算、10進演算のため小数第 4 位まで手計算と一致確認済み):
    //   内蔵.mmRect = (0, 0, 275.0928, 178.2189)   (= 2056*0.1338, 1329*0.1341)
    //   LG.mmRect   = (-219.9666, -333.936, 576.0494, 0)
    //     - LG.mm.minY = 0 - 1440*0.2319 = -333.936 (内蔵.top に接する形で上に伸びる)
    //     - LG.mm.maxY = -333.936 + 1440*0.2319 = 0 = 内蔵.mm.minY (接触辺が mm 空間でも接する)
    //     - mmX_内蔵(xc=1028) = 0 + 1028*0.1338 = 137.5464
    //     - LG.mm.minX = 137.5464 - (1028 - (-517))*0.2314 = 137.5464 - 357.513 = -219.9666
    //     - LG.mm.maxX = -219.9666 + 3440*0.2314 = -219.9666 + 796.016 = 576.0494
    func testRealDeviceConfigurationInternalAndLGAboveIt() {
        let builtIn = Display(
            id: "builtin",
            logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 0.1338, scaleY: 0.1341))
        let lg = Display(
            id: "lg",
            logicalBounds: LogicalRect(minX: -517, minY: -1440, maxX: 2923, maxY: 0),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 0.2314, scaleY: 0.2319))

        let placements = WaveLayout.placements(displays: [builtIn, lg])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(
            byId["builtin"]!.mmRect,
            PhysicalRect(minX: 0, minY: 0, maxX: 275.0928, maxY: 178.2189),
            "内蔵は anchor (論理 (0,0) を containsHalfOpen) なので mm.min = (0,0)")
        assertMMRectEqual(
            byId["lg"]!.mmRect,
            PhysicalRect(minX: -219.9666, minY: -333.936, maxX: 576.0494, maxY: 0))

        // DR-0011 決定 2 の固定条件: 接触辺 (LG.maxY == 内蔵.minY) は mm 空間でも一致する。
        XCTAssertEqual(byId["lg"]!.mmRect.maxY, byId["builtin"]!.mmRect.minY, accuracy: 1e-9,
                        "接触辺は scale が違っても mm 空間で一致し続ける (固定軸なので誤差なし)")

        // 接触区間の中点 (論理 x=1028) を両 display の写像で mm 化すると一致する
        // (直交方向は中点でのみ整合を取る設計、DR-0011 決定 2)。
        let midpointOnBuiltIn = byId["builtin"]!.toMM(LogicalPoint(x: 1028, y: 0))
        let midpointOnLG = byId["lg"]!.toMM(LogicalPoint(x: 1028, y: 0))
        XCTAssertEqual(midpointOnBuiltIn.x, midpointOnLG.x, accuracy: 1e-6,
                        "接触区間の中点は scale が違う隣接同士でも mm 空間で一致する")
    }

    // ================================
    // (b) 横並び 2 枚、同一 scale (= 論理配置と mm 配置が平行移動のみで一致する単純ケース)
    // ================================
    //
    // A (0,0)-(1000,800) scale(1,1) [anchor]、B (1000,0)-(2000,800) scale(1,1)。
    // 完全に Y 範囲が一致するので overlap 中点 yc=400、A.mmY(400)=400、B.mm.minY も 0 になるはず
    // (= 縦方向のズレなしで並ぶ、直感通りの結果になることの固定)。
    func testHorizontalPairSameScaleAlignsWithoutVerticalOffset() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800), pose: .identity)
        let b = Display(
            id: "B", logicalBounds: LogicalRect(minX: 1000, minY: 0, maxX: 2000, maxY: 800), pose: .identity)

        let placements = WaveLayout.placements(displays: [a, b])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(byId["A"]!.mmRect, PhysicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800))
        assertMMRectEqual(byId["B"]!.mmRect, PhysicalRect(minX: 1000, minY: 0, maxX: 2000, maxY: 800),
                           "同一 scale・同一 Y 範囲なら縦方向オフセットなしで右に並ぶ")
    }

    // ================================
    // (c) 3 枚チェーン (A - B - C、C は B にのみ接触し A には接触しない、経路上で scale が変わる)
    // ================================
    //
    // A (anchor, 0,0)-(1000,1000) scale(1,1)
    // B (A の右、1000,200)-(1600,800) scale(2,2)
    //   overlap Y = [max(0,200), min(1000,800)] = [200,800]、yc=500
    //   mmY_A(500) = 0 + 500*1 = 500
    //   B.mm.minY = 500 - (500-200)*2 = 500-600 = -100
    //   B.mm.minX = A.mm.maxX = 0 + 1000*1 = 1000
    //   B.mmRect = (1000, -100, 1000+600*2, -100+600*2) = (1000, -100, 2200, 1100)
    // C (B の下、1100,800)-(1500,1100) scale(0.5,0.5)。B.maxY(800) == C.minY(800) で接触。
    //   A とは X 範囲 [0,1000] vs [1100,1500] が重ならず非接触 (BFS は B 経由でのみ到達)。
    //   overlap X = [max(1000,1100), min(1600,1500)] = [1100,1500]、xc=1300
    //   mmX_B(1300) = 1000 + (1300-1000)*2 = 1600
    //   C.mm.minX = 1600 - (1300-1100)*0.5 = 1600-100 = 1500
    //   C.mm.minY = B.mm.maxY = -100 + 600*2 = 1100
    //   C.mmRect = (1500, 1100, 1500+400*0.5, 1100+300*0.5) = (1500, 1100, 1700, 1250)
    func testThreeDisplayChainWithMixedScalesPropagatesThroughIntermediateNode() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000), pose: .identity)
        let b = Display(
            id: "B", logicalBounds: LogicalRect(minX: 1000, minY: 200, maxX: 1600, maxY: 800),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 2, scaleY: 2))
        let c = Display(
            id: "C", logicalBounds: LogicalRect(minX: 1100, minY: 800, maxX: 1500, maxY: 1100),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 0.5, scaleY: 0.5))

        let placements = WaveLayout.placements(displays: [a, b, c])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(byId["A"]!.mmRect, PhysicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000))
        assertMMRectEqual(byId["B"]!.mmRect, PhysicalRect(minX: 1000, minY: -100, maxX: 2200, maxY: 1100))
        assertMMRectEqual(byId["C"]!.mmRect, PhysicalRect(minX: 1500, minY: 1100, maxX: 1700, maxY: 1250),
                           "C は A と論理的に非接触 (X 範囲が重ならない) なので BFS は B 経由で到達する")
    }

    // ================================
    // (d) 角のみ接触 → fallback (非接触扱い)
    // ================================
    //
    // A (anchor, 0,0)-(1000,1000) scale(1,1)、D (1000,1000)-(1500,1500) scale(1,1)。
    // A.maxX==D.minX だが Y overlap = [max(0,1000), min(1000,1500)] = [1000,1000] で長さ 0
    // (= 角のみの接触)、同様に A.maxY==D.minY 側も X overlap 長さ 0。DR-0011 決定 2 により
    // 「角のみの接触は非接触扱い」なので D は BFS で到達できず fallback (translate=0 相当) になる。
    func testCornerOnlyContactIsTreatedAsDisconnectedAndUsesFallback() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000), pose: .identity)
        let d = Display(
            id: "D", logicalBounds: LogicalRect(minX: 1000, minY: 1000, maxX: 1500, maxY: 1500), pose: .identity)

        let placements = WaveLayout.placements(displays: [a, d])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(byId["A"]!.mmRect, PhysicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000))
        // fallback: mmRect.min = (logical.minX*scaleX, logical.minY*scaleY) = (1000*1, 1000*1)
        assertMMRectEqual(byId["D"]!.mmRect, PhysicalRect(minX: 1000, minY: 1000, maxX: 1500, maxY: 1500),
                           "角のみ接触は非接触扱いなので fallback (translate=0 相当) に落ちる")
    }

    // ================================
    // (e) 非連結 (完全に離れた 2 枚、scale も異なる)
    // ================================
    //
    // A (anchor, 0,0)-(1000,1000) scale(1,1)、E (5000,5000)-(5300,5200) scale(3,4) (どの辺も
    // 接触しない)。fallback: mmRect.min = (5000*3, 5000*4) = (15000, 20000)、
    // 幅高 = (300*3, 200*4) = (900, 800)。
    func testDisjointDisplaysUseIndependentFallbackMapping() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000), pose: .identity)
        let e = Display(
            id: "E", logicalBounds: LogicalRect(minX: 5000, minY: 5000, maxX: 5300, maxY: 5200),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 3, scaleY: 4))

        let placements = WaveLayout.placements(displays: [a, e])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(byId["A"]!.mmRect, PhysicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000))
        assertMMRectEqual(byId["E"]!.mmRect, PhysicalRect(minX: 15000, minY: 20000, maxX: 15900, maxY: 20800),
                           "非連結成分は translate=0 相当の独立 fallback で mm 空間へ写像される")
    }

    // ================================
    // (f) scale が違う隣接同士の中点整合 (縦方向接触、上下 scale が異なるケースを別途固定)
    // ================================
    //
    // A (anchor, 0,0)-(1000,600) scale(1,1)、F (A の下、200,600)-(800,900) scale(3,3)。
    // A.maxY(600)==F.minY(600) で接触。overlap X = [max(0,200), min(1000,800)] = [200,800]、
    // xc=500。mmX_A(500)=500。F.mm.minX = 500 - (500-200)*3 = 500-900 = -400。
    // 中点 (論理 x=500, y=600 の接触辺上の点) を両 display の toMM で変換すると mm x が一致する
    // ことを、WavePlacement.toMM 経由で直接確認する (実装詳細でなく公開 API での固定)。
    func testVerticalPairWithDifferentScaleAlignsAtOverlapMidpointViaToMM() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 600), pose: .identity)
        let f = Display(
            id: "F", logicalBounds: LogicalRect(minX: 200, minY: 600, maxX: 800, maxY: 900),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 3, scaleY: 3))

        let placements = WaveLayout.placements(displays: [a, f])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(byId["F"]!.mmRect, PhysicalRect(minX: -400, minY: 600, maxX: 1400, maxY: 1500))

        let midpointOnA = byId["A"]!.toMM(LogicalPoint(x: 500, y: 600))
        let midpointOnF = byId["F"]!.toMM(LogicalPoint(x: 500, y: 600))
        XCTAssertEqual(midpointOnA.x, midpointOnF.x, accuracy: 1e-9,
                        "overlap 区間の中点 (x=500) は scale が異なっても mm 空間で一致する")
        XCTAssertEqual(midpointOnA.y, midpointOnF.y, accuracy: 1e-9,
                        "接触辺 (y=600) は固定軸なので厳密に一致する")

        // 中点から離れた点 (x=200, 接触区間の端) は scale が違う限り一致しない
        // (DR-0011 が保証するのは中点のみ、区間全体の連続性ではないことの明示固定)。
        let edgeOnA = byId["A"]!.toMM(LogicalPoint(x: 200, y: 600))
        let edgeOnF = byId["F"]!.toMM(LogicalPoint(x: 200, y: 600))
        XCTAssertNotEqual(edgeOnA.x, edgeOnF.x, accuracy: 1e-9,
                           "中点以外は scale 差により mm 座標がズレる (仕様上の許容範囲)")
    }

    // ================================
    // localPx (mm → view-local px) の往復確認
    // ================================
    //
    // WavePlacement.toMM の逆写像であることを、mmRect.min / mmRect の中心相当点で確認する。
    // localPx(mmRect.min) は常に (0,0) (= view 左上原点)。
    func testLocalPxRoundTripsWithToMM() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 100, minY: 50, maxX: 1100, maxY: 850),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 0.2, scaleY: 0.25))
        let placements = WaveLayout.placements(displays: [a])
        let placement = placements[0]

        // anchor なので mmRect.min = (0,0)
        assertMMPointEqual(PhysicalPoint(x: placement.mmRect.minX, y: placement.mmRect.minY), PhysicalPoint(x: 0, y: 0))

        let localOfMin = placement.localPx(fromMM: PhysicalPoint(x: placement.mmRect.minX, y: placement.mmRect.minY))
        XCTAssertEqual(localOfMin.x, 0, accuracy: 1e-9, "mmRect.min の local px は view 左上原点 (0,0)")
        XCTAssertEqual(localOfMin.y, 0, accuracy: 1e-9)

        // 論理座標 (600, 450) (= display 内部の任意点) を toMM → localPx で往復させると、
        // 「anchor からの相対 px」= (600-100, 450-50) = (500, 400) に一致する
        // (anchor の logicalBounds.minX/minY を差し引いた view-local 座標になるため)。
        let midLogical = LogicalPoint(x: 600, y: 450)
        let midMM = placement.toMM(midLogical)
        let midLocal = placement.localPx(fromMM: midMM)
        XCTAssertEqual(midLocal.x, 500, accuracy: 1e-9)
        XCTAssertEqual(midLocal.y, 400, accuracy: 1e-9)
    }

    // ================================
    // (g) eps=0.5px 接触許容の境界 (WaveLayout.touchEpsilon、実機の max 側 -0.02px clamp を吸収)
    // ================================
    //
    // A (anchor, 0,0)-(2055.98,1329) scale(1,1)、B (2056,0)-(3056,800) scale(1,1)。
    // gap = 2056 - 2055.98 = 0.02px (<= eps 0.5) → 接触扱い (docs/findings/
    // 2026-07-09-macos-display-api-verification.md §4 の実機 max 側 -0.02px clamp を模した値)。
    // B.mm.minX = mmX_A(2055.98) = 2055.98。yc = overlapMidpoint(A.y:0..1329, B.y:0..800) = 400。
    // B.mm.minY = mmY_A(400) - (400-0)*1 = 400-400 = 0 (B の scale=1 なので A の写像そのまま)。
    func testEpsilonBoundaryGapWithinEpsilonIsTreatedAsTouching() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 2055.98, maxY: 1329), pose: .identity)
        let b = Display(
            id: "B", logicalBounds: LogicalRect(minX: 2056, minY: 0, maxX: 3056, maxY: 800), pose: .identity)

        let placements = WaveLayout.placements(displays: [a, b])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(
            byId["B"]!.mmRect, PhysicalRect(minX: 2055.98, minY: 0, maxX: 3055.98, maxY: 800),
            "gap=0.02px (<= eps 0.5) は接触扱いなので BFS で A に隣接配置される (fallback ではない)")
    }

    /// 同条件で gap を eps (0.5px) 超に広げると非接触扱いになり、B は fallback (translate=0 相当)
    /// に落ちる (mmRect.min = (logical.minX*scaleX, logical.minY*scaleY) = (2057, 0))。
    func testGapExceedingEpsilonIsTreatedAsDisconnectedAndFallsBack() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329), pose: .identity)
        let c = Display(
            id: "C", logicalBounds: LogicalRect(minX: 2057, minY: 0, maxX: 3057, maxY: 800), pose: .identity)

        let placements = WaveLayout.placements(displays: [a, c])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(
            byId["C"]!.mmRect, PhysicalRect(minX: 2057, minY: 0, maxX: 3057, maxY: 800),
            "gap=1.0px (> eps 0.5) は非接触扱いなので fallback (translate=0 相当) に落ちる")
    }

    // ================================
    // (h) anchor 辞書順 fallback (論理 (0,0) を含む display が存在しない構成)
    // ================================
    //
    // どの display も論理 (0,0) を containsHalfOpen しない (全て minX>0 かつ minY>0)。
    // WaveLayout.selectAnchorIndex は (minY, minX) 辞書順最小を anchor に選ぶ (DR-0011 決定 2)。
    // D1=(minY,minX)=(1000,1000)、D2=(5000,5000)、D3=(10,5)。辞書順で D3 < D1 < D2 なので
    // D3 が anchor になり mmRect.min=(0,0) を得る。3 枚は互いに接触しないので D1/D2 は fallback
    // だが本テストの主眼は「anchor 選択そのもの」なので D3 側だけを assert する。
    func testAnchorFallsBackToLexicographicMinYMinXWhenNoDisplayContainsOrigin() {
        let d1 = Display(
            id: "D1", logicalBounds: LogicalRect(minX: 1000, minY: 1000, maxX: 2000, maxY: 1800), pose: .identity)
        let d2 = Display(
            id: "D2", logicalBounds: LogicalRect(minX: 5000, minY: 5000, maxX: 6000, maxY: 5800), pose: .identity)
        let d3 = Display(
            id: "D3", logicalBounds: LogicalRect(minX: 5, minY: 10, maxX: 1005, maxY: 810), pose: .identity)

        let placements = WaveLayout.placements(displays: [d1, d2, d3])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMPointEqual(
            PhysicalPoint(x: byId["D3"]!.mmRect.minX, y: byId["D3"]!.mmRect.minY), PhysicalPoint(x: 0, y: 0),
            "(minY,minX)=(10,5) が 3 枚中の辞書順最小なので D3 が anchor になり mmRect.min=(0,0)")
    }

    // ================================
    // (i) BFS 複数親: 2x2 田の字配置 (4 枚が互いに接触、サイクルあり) の first-parent-wins 固定
    // ================================
    //
    // A (anchor, 左上) (0,0)-(1000,1000) scale(1,1)
    // B (右上、A の右)  (1000,0)-(2000,1000) scale(2,2)
    // C (左下、A の下)  (0,1000)-(1000,2000) scale(3,3)
    // D (右下)          (1000,1000)-(2000,2000) scale(1,1)
    // D は B (上辺接触) にも C (左辺接触) にも接触し、B-C 間は直接非接触 (D 経由でのみサイクル)。
    // A-D は角のみ接触 (Y/X overlap いずれも 0) で非接触。
    //
    // WaveLayout.placements の実装 (edges 構築は `for j in 0..<count` の index 昇順、BFS は
    // queue.removeFirst() の FIFO) により、displays 配列を [A,B,C,D] (index 0..3) の順で渡すと:
    //   - edges[A] は j 昇順で (B,.right) → (C,.bottom) の順に積まれる
    //   - BFS: A を処理 → B, C の順に visited化・enqueue (queue=[B,C])
    //   - B を先に dequeue → edges[B] に (D,.bottom) があり D 未訪問 → D は B 経由で visited化・
    //     enqueue (queue=[C,D])
    //   - 次に C を dequeue → edges[C] に (D,.right) があるが D は既に visited 済みなので skip
    //   → D の親は B に確定する (= 「実装の探訪順序が決定的であること」自体を固定するテストであり、
    //     期待値は実装の index 順・FIFO 規則から導出したもので、実装に後から合わせたものではない)
    //
    // D の mm 配置を「B 経由」と「C 経由」で計算すると scale の非対称性 (B=2倍, C=3倍) により
    // 異なる値になる (このテストはその分岐を検出できる、= 単なる偶然の一致を固定するテストではない):
    //   - B 経由 (実装が採用する経路): D.mmMin = (1500, 1500)
    //   - C 経由 (採用されない方): D.mmMin = (2000, 2000) (参考、assert しない)
    //
    // B 経由の導出:
    //   B.mmMin = A から .right で導出 = (1000, -500)
    //     (childMinX = mmX_A(A.maxX=1000) = 1000。yc=overlapMidpoint(A.y:0..1000,B.y:0..1000)=500。
    //      targetMMY = mmY_A(500) = 500。childMinY = 500 - (500-0)*B.scaleY(2) = -500)
    //   D (parent=B, side=.bottom):
    //     childMinY = mmY_B(B.maxY=1000) = -500 + (1000-0)*2 = 1500
    //     xc = overlapMidpoint(B.x:1000..2000, D.x:1000..2000) = 1500
    //     targetMMX = mmX_B(1500) = 1000 + (1500-1000)*2 = 2000
    //     childMinX = 2000 - (1500-1000)*D.scaleX(1) = 1500
    //   → D.mmMin = (1500, 1500)、D.mmRect = (1500, 1500, 2500, 2500)
    func testBFSMultipleParentsInSquareCycleResolvesToFirstParentDeterministically() {
        let a = Display(
            id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 1000), pose: .identity)
        let b = Display(
            id: "B", logicalBounds: LogicalRect(minX: 1000, minY: 0, maxX: 2000, maxY: 1000),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 2, scaleY: 2))
        let c = Display(
            id: "C", logicalBounds: LogicalRect(minX: 0, minY: 1000, maxX: 1000, maxY: 2000),
            pose: DisplayPose(translate: .init(x: 0, y: 0), scaleX: 3, scaleY: 3))
        let d = Display(
            id: "D", logicalBounds: LogicalRect(minX: 1000, minY: 1000, maxX: 2000, maxY: 2000), pose: .identity)

        let placements = WaveLayout.placements(displays: [a, b, c, d])
        let byId = Dictionary(uniqueKeysWithValues: placements.map { ($0.displayId, $0) })

        assertMMRectEqual(
            byId["D"]!.mmRect, PhysicalRect(minX: 1500, minY: 1500, maxX: 2500, maxY: 2500),
            "サイクルがあっても BFS の実装順序 (index 昇順 + FIFO) により D の親は決定的に B に定まる")
    }
}
