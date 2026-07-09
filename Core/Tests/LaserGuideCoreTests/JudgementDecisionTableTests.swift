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
    ///     y=500 で越境しようとしたので user 側は空 = PB。
    ///
    /// clampTo は交点座標 (1920, 500) ちょうどではなく、source display (A) 内側へ 0.25 論理 px
    /// 分だけ引き込んだ座標になる (2026-07-10 コアレビュー C-2)。半開区間規約 ([minX, maxX)) の下では
    /// x=1920 ちょうどは B の所属になってしまい、PB の意図 (A 側に留める) を裏切るため。
    func testPB_UserAbsentAtCrossing() {
        // user は上端 [0,300] のみ
        let users: [PassSegment] = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-A"),
        ]
        let tables = WarpTables(displays: makeDisplays(), userSegments: users)
        let line = LineSegment(from: LogicalPoint(x: 1900, y: 500), to: LogicalPoint(x: 1940, y: 500))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        guard case let .pb(clamp) = j else {
            return XCTFail("expected .pb, got \(j)")
        }
        // along (y) は交点のまま、固定軸 (x) だけ A の内側 (-x 方向) へ 0.25 px 引き込まれる。
        XCTAssertEqual(clamp.y, 500, accuracy: 1e-9, "along 座標 (y) は交点のまま変わらない")
        XCTAssertEqual(clamp.x, 1920 - 0.25, accuracy: 1e-9, "固定軸 (x) は A 内側へ 0.25 論理 px")
        XCTAssertTrue(clamp.x < 1920, "半開区間規約下で A (x<1920) の所属になる位置であること")
        XCTAssertEqual(tables.displayId(containing: clamp), "A", "クランプ後の座標は A に所属すること")
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
    // 複数辺交差の選択 (m-2 minor)
    // ==================

    /// カド越しの移動線分が A の right 辺・bottom 辺の両方の infinite line と交わりうる場合でも、
    /// 凸矩形の境界を横切る直線は通常どちらか一方でしか along レンジ内の有効な交点を持たない
    /// (両方が有効になるのは線分がカド頂点をちょうど通る退化ケースのみ、数学的に t が完全一致する)。
    /// このテストは「配列順 (= Adjacency 生成順、A-B ペアが先) ではなく t 最小で選ぶ」実装が、
    /// t が同点のカド頂点通過ケースでもクラッシュせず決定的な結果を返すことを固定する
    /// (同点時は先に見つかった方 = 配列順が残る、という決定性そのものを仕様として固定する)。
    func testCornerThroughLineIsHandledDeterministicallyByTMinSelection() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let b = Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity)
        let d = Display(id: "D", logicalBounds: LogicalRect(minX: 0, minY: 1080, maxX: 1920, maxY: 2160), pose: .identity)
        let tables = WarpTables(displays: [a, b, d], userSegments: [])
        // A の右下カド (1920, 1080) をちょうど通る対角線 (t_right = t_bottom = 0.5)
        let line = LineSegment(from: LogicalPoint(x: 1900, y: 1060), to: LogicalPoint(x: 1940, y: 1100))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "A", tables: tables)
        guard case let .pb(clamp) = j else {
            return XCTFail("expected .pb (user segment なしで両候補とも PB), got \(j)")
        }
        // 同点時は Adjacency 生成順で先に登録される A-B (right) 側が採用される: along (y) は交点のまま、
        // 固定軸 (x) だけ内側へ引き込まれる (bottom 側が採用されていれば逆に y だけ動くはず)。
        XCTAssertEqual(clamp.y, 1080, accuracy: 1e-9, "right 側採用なら along (y) は交点のまま")
        XCTAssertEqual(clamp.x, 1920 - RateMapping.boundaryInwardInsetLogicalPixels, accuracy: 1e-9, "right 側採用なら x が内側へ")
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

    /// M-1: OS がこの along 位置を通す辺 (= osSegment が存在) なら、BX 判定として呼ばれたこと自体が
    /// 誤検出 (エッジ ε 近傍の丸め等)。userSegment がフルカバーで存在していても block を返し、
    /// 誤ってワープを発生させない。
    func testM1_OSPassesHereOverridesEvenWithFullyOverlappingUserSegment() {
        let tables = WarpTables(displays: makeDisplays(), userSegments: userSegmentsFullOverlap())
        // A.right (x=1920, y=500) は OS 隣接 (B) がある辺。本来 BX ではなく PX (PP) になるはずの
        // 位置だが、ε near-edge の丸め等で誤って BX 経路に来たケースを模擬する。
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 1920, y: 500), displayId: "A", side: .right, tables: tables)
        XCTAssertEqual(outcome, .block, "OS が通す辺での BX は誤検出、userSegment の有無に関わらず block")
    }

    /// m-5: userSegment 自体は存在するが、pairedSegmentId が指す先の segment がテーブルに存在しない
    /// (削除済み / 未定義参照)。ワープしない点は BB と同じだが `.blockDanglingReference` として
    /// 原因を区別できることを固定する (DR-0007 決定 7 の inactive 可視化)。
    func testM5_DanglingPairedSegmentReferenceIsDistinguishedFromPlainBlock() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let users = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-gone"),
        ]
        let tables = WarpTables(displays: [a], userSegments: users)
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 1920, y: 500), displayId: "A", side: .right, tables: tables)
        XCTAssertEqual(outcome, .blockDanglingReference(pairedSegmentId: "u-gone"))
    }

    // ==================
    // BX 2 段評価 (M-2)
    // ==================

    /// M-2: カドで優先辺 (bottom) が BB (userSegment なし)、次候補辺 (right) が BP (仮想接続あり) の
    /// 場合、`judgeBlockedWithFallback` は先頭で block に終わらず次候補を試して pass を返す。
    /// findings §5e (カドで両軸の delta が流れ続ける実機観測) と整合するシナリオ。
    func testM2_FallbackTriesNextCandidateWhenPrimarySideIsBlocked() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        // bottom 辺には userSegment なし (BB)、right 辺には C への仮想接続 (BP)
        let users = [
            PassSegment(id: "u-A-right", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C-left"),
            PassSegment(id: "u-C-left", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A-right"),
        ]
        let tables = WarpTables(displays: [a, c], userSegments: users)
        // カド (1920, 1080) 付近、優先度 top→bottom→left→right で bottom が先、right が次候補。
        let outcome = Judgement.judgeBlockedWithFallback(
            at: LogicalPoint(x: 1920, y: 1080),
            displayId: "A", sides: [.bottom, .right],
            tables: tables, inwardInsetMillimeters: 0)
        if case let .pass(dst) = outcome {
            XCTAssertEqual(dst.x, 5000, accuracy: 1e-9, "right 候補 (C への仮想接続) の着地先")
        } else {
            XCTFail("expected .pass (フォールバックで right が採用される), got \(outcome)")
        }
    }

    /// M-2: 全候補が block ならフォールバックしても block のまま (先頭候補の結果を保つ)。
    func testM2_FallbackReturnsBlockWhenAllCandidatesBlocked() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let tables = WarpTables(displays: [a], userSegments: [])
        let outcome = Judgement.judgeBlockedWithFallback(
            at: LogicalPoint(x: 1920, y: 1080), displayId: "A", sides: [.bottom, .right], tables: tables)
        XCTAssertEqual(outcome, .block)
    }

    // ==================
    // WarpTables.edgeType (m-6: UI render model 用の EdgeType 導出)
    // ==================

    /// osSegments/userSegments の所属差分から EdgeType (PP/PB/BP/BB) が正しく導出されることを、
    /// 4 状態それぞれで固定する (judgeCrossing/judgeBlocked の判定と同じ入力を EdgeType 語彙で再確認)。
    func testEdgeTypeDerivesAllFourStatesFromSegmentMembership() {
        // PP/PB: A-B は OS 隣接あり。y<300 は userSegment もあり (PP)、y=500 は userSegment なし (PB)。
        let partialUsers: [PassSegment] = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-A"),
        ]
        let tablesAB = WarpTables(displays: makeDisplays(), userSegments: partialUsers)
        XCTAssertEqual(tablesAB.edgeType(displayId: "A", side: .right, along: 150), .pp, "OS あり + user あり (y=150 は user 範囲内)")
        XCTAssertEqual(tablesAB.edgeType(displayId: "A", side: .right, along: 500), .pb, "OS あり + user なし (y=500 は user 範囲外)")

        // BP/BB: A-C は OS 隣接なし (物理的に離れている)。ユーザ接続がある場合 (BP) とない場合 (BB)。
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        let bridgingUsers = [
            PassSegment(id: "u-A2", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A2"),
        ]
        let tablesAC = WarpTables(displays: [a, c], userSegments: bridgingUsers)
        XCTAssertEqual(tablesAC.edgeType(displayId: "A", side: .right, along: 500), .bp, "OS なし + user あり")

        let tablesANoUser = WarpTables(displays: [a, c], userSegments: [])
        XCTAssertEqual(tablesANoUser.edgeType(displayId: "A", side: .right, along: 500), .bb, "OS なし + user なし")
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

    // ==================
    // PB 縦方向 (top/bottom) の inset 符号検証
    // (2026-07-10 第 2 ラウンド b: 実機で「移動先モニタ側に少しはみ出た位置に留まる」観測があり、
    //  inwardClampedPoint の top/bottom inset 符号が source の外側を向いている疑いが出た。
    //  既存の PB テストは left/right (垂直エッジ) のみだったため、水平エッジでも符号を固定する。)
    // ==================

    /// 内蔵 (下、id "Down") の top エッジ (minY=0) に Up (id "Up") が接触する縦構成。
    /// x=500 で PB (Up 側のユーザセグメントが x∈[0,300] にしかない) → clampTo は
    /// source (Down) の内側、つまり y = minY + 0.25 (+y 方向、Down の内部は y が大きい方) になる。
    /// これが逆符号 (-y、Up 側へはみ出す方向) なら bug。
    func testPB_TopEdgeVertical_ClampsInwardTowardSourceInterior() {
        let down = Display(id: "Down", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let up = Display(id: "Up", logicalBounds: LogicalRect(minX: 0, minY: -1080, maxX: 1920, maxY: 0), pose: .identity)
        let users: [PassSegment] = [
            PassSegment(id: "u-Down", displayId: "Down", side: .top, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-Up"),
            PassSegment(id: "u-Up", displayId: "Up", side: .bottom, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-Down"),
        ]
        let tables = WarpTables(displays: [down, up], userSegments: users)
        // Down 内部 (y=20) から Up 方向 (y 減少) へ x=500 で継ぎ目 (y=0) を越境
        let line = LineSegment(from: LogicalPoint(x: 500, y: 20), to: LogicalPoint(x: 500, y: -20))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "Down", tables: tables)
        guard case let .pb(clamp) = j else {
            return XCTFail("expected .pb (x=500 は user 範囲外), got \(j)")
        }
        XCTAssertEqual(clamp.x, 500, accuracy: 1e-9, "along (x) は交点のまま変わらない")
        XCTAssertEqual(clamp.y, 0 + 0.25, accuracy: 1e-9, "top エッジの内向きは +y (Down の内部は y が大きい方)")
        XCTAssertTrue(clamp.y > 0, "はみ出さず Down (y>=0) 側に留まっていること")
        XCTAssertEqual(tables.displayId(containing: clamp), "Down", "クランプ後の座標は source (Down) に所属すること")
    }

    /// SourceB (上、id "SourceB") の bottom エッジ (maxY=1080) に Below (id "Below") が接触する
    /// 縦構成。x=500 で PB → clampTo は source (SourceB) の内側、つまり y = maxY − 0.25
    /// (-y 方向、SourceB の内部は y が小さい方) になる。逆符号なら bug。
    func testPB_BottomEdgeVertical_ClampsInwardTowardSourceInterior() {
        let sourceB = Display(id: "SourceB", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let below = Display(id: "Below", logicalBounds: LogicalRect(minX: 0, minY: 1080, maxX: 1920, maxY: 2160), pose: .identity)
        let users: [PassSegment] = [
            PassSegment(id: "u-SourceB", displayId: "SourceB", side: .bottom, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-Below"),
            PassSegment(id: "u-Below", displayId: "Below", side: .top, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-SourceB"),
        ]
        let tables = WarpTables(displays: [sourceB, below], userSegments: users)
        // SourceB 内部 (y=1060) から Below 方向 (y 増加) へ x=500 で継ぎ目 (y=1080) を越境
        let line = LineSegment(from: LogicalPoint(x: 500, y: 1060), to: LogicalPoint(x: 500, y: 1100))
        let j = Judgement.judgeCrossing(line: line, sourceDisplayId: "SourceB", tables: tables)
        guard case let .pb(clamp) = j else {
            return XCTFail("expected .pb (x=500 は user 範囲外), got \(j)")
        }
        XCTAssertEqual(clamp.x, 500, accuracy: 1e-9, "along (x) は交点のまま変わらない")
        XCTAssertEqual(clamp.y, 1080 - 0.25, accuracy: 1e-9, "bottom エッジの内向きは -y (SourceB の内部は y が小さい方)")
        XCTAssertTrue(clamp.y < 1080, "はみ出さず SourceB (y<1080) 側に留まっていること")
        XCTAssertEqual(tables.displayId(containing: clamp), "SourceB", "クランプ後の座標は source (SourceB) に所属すること")
    }

    /// BP (仮想接続ワープ) の縦方向 inset も同じ物理→論理変換関数 (physicalToLogicalInsetVector) を
    /// 共有しているため、min 側 (top) 着地でも符号を固定しておく (実機症状「移動先モニタ側に少し
    /// はみ出る」の疑いの本命は着地側のこの経路)。paired (D) の top エッジ (minY=5000) へ着地 →
    /// inset は +y (D の内部方向)、はみ出す方向 (-y、エッジより外) になっていないことを固定する。
    func testBP_InwardInsetVertical_TopSide_PushesWarpDestinationInsidePairedDisplay() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        // D の scaleY = 0.5 mm/px → inset 1mm は 2px 相当
        let d = Display(id: "D", logicalBounds: LogicalRect(minX: 0, minY: 5000, maxX: 1920, maxY: 6080),
                        pose: DisplayPose(translate: PhysicalPoint(x: 0, y: 0), scaleX: 0.5, scaleY: 0.5))
        let users = [
            PassSegment(id: "u-A", displayId: "A", side: .bottom, logicalStart: 0, logicalEnd: 1920, pairedSegmentId: "u-D"),
            PassSegment(id: "u-D", displayId: "D", side: .top, logicalStart: 0, logicalEnd: 1920, pairedSegmentId: "u-A"),
        ]
        let tables = WarpTables(displays: [a, d], userSegments: users)
        let outcome = Judgement.judgeBlocked(
            at: LogicalPoint(x: 500, y: 1080),
            displayId: "A", side: .bottom,
            tables: tables,
            inwardInsetMillimeters: 1.0)
        if case let .pass(dst) = outcome {
            XCTAssertEqual(dst.y, 5000 + 2, accuracy: 1e-9, "top 着地は +y (D の内側) へ 2px、D の外へはみ出していない")
            XCTAssertTrue(dst.y > 5000, "D (y>=5000) の内側に留まっていること")
        } else {
            XCTFail("expected .pass, got \(outcome)")
        }
    }
}
