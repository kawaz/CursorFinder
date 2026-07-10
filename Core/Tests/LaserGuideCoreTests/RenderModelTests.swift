// RenderModel の導出テスト (DR-0008: WKWebView 純 view の Swift 正本)
//
// 「AppState の変化列 → RenderModel の変化列」で検証する。この 1 レイヤーが正しければ、
// JS 側は「与えられた JSON を描くだけ」で表示が仕様に追従する (幾何ロジックの二重実装が排除される)。
import XCTest
@testable import LaserGuideCore

final class RenderModelTests: XCTestCase {

    // ==================
    // 共通ヘルパー
    // ==================

    private func twoDisplays(idA: String = "A", idB: String = "B") -> [Display] {
        [
            Display(id: idA, logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: idB, logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
    }

    // ==================
    // (1) 論理・物理矩形と pose の表示
    // ==================

    /// pose が identity のとき、physicalBounds = logicalBounds (scale=1, translate=0)。
    /// 「JS 側は physicalBounds を描くだけ」の契約が identity で成立することを固定する。
    func testIdentityPoseMakesPhysicalBoundsEqualLogicalBounds() {
        let state = AppState.initial(displays: twoDisplays())
        let m = RenderModel.derive(from: state)
        XCTAssertEqual(m.displays.count, 2)
        for d in m.displays {
            XCTAssertEqual(d.physicalBounds.minX, d.logicalBounds.minX)
            XCTAssertEqual(d.physicalBounds.maxX, d.logicalBounds.maxX)
            XCTAssertEqual(d.physicalBounds.minY, d.logicalBounds.minY)
            XCTAssertEqual(d.physicalBounds.maxY, d.logicalBounds.maxY)
            XCTAssertEqual(d.poseTranslateMm, RenderModel.Point(x: 0, y: 0))
            XCTAssertEqual(d.scaleXMmPerPx, 1)
            XCTAssertEqual(d.scaleYMmPerPx, 1)
            XCTAssertNil(d.candidatePoseTranslateMm)
            XCTAssertFalse(d.isDragging)
        }
        XCTAssertNil(m.draggingDisplayId)
        XCTAssertFalse(m.hasPreview)
        XCTAssertEqual(m.yAxisDirection, "down")
    }

    /// scale と translate 両方が効く: 1080 px 幅を scale=0.25 mm/px、translate=(100,50) で
    /// physicalBounds = (100 + 0*0.25, 50 + 0*0.25) .. (100 + 1920*0.25, 50 + 1080*0.25) = (100,50)..(580,320)。
    func testPhysicalBoundsAppliesScaleAndTranslate() {
        let d = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080),
                        pose: DisplayPose(translate: PhysicalPoint(x: 100, y: 50), scaleX: 0.25, scaleY: 0.25))
        let state = AppState(displays: [d], userSegments: [])
        let m = RenderModel.derive(from: state)
        let rect = m.displays[0].physicalBounds
        XCTAssertEqual(rect.minX, 100, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 50, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX, 100 + 1920 * 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.maxY, 50 + 1080 * 0.25, accuracy: 1e-9)
    }

    // ==================
    // (2) セグメント一覧と EdgeType 導出
    // ==================

    /// 2 モニタの OS 隣接 + userSegments が osSegments の全 span を丸ごとカバー (PP) するとき、
    /// segments には os / user 双方が並び、両者の edgeType は "pp" になる。
    func testSegmentsIncludeBothOSAndUserWithPPWhenFullyCovered() {
        let state = AppState.initial(displays: twoDisplays())  // AppState.initial = userSegments = OS コピー = PP
        let m = RenderModel.derive(from: state)
        // OS ペア (A-B, B-A) と User ペア (A-B, B-A) の合計 4 セグメント
        let osSegs = m.segments.filter { $0.source == "os" }
        let userSegs = m.segments.filter { $0.source == "user" }
        XCTAssertEqual(osSegs.count, 2)
        XCTAssertEqual(userSegs.count, 2)
        for s in m.segments { XCTAssertEqual(s.edgeType, "pp", "全カバー時は PP") }
    }

    /// userSegments を空にすると、OS 隣接は覆われないので os 側の edgeType は "pb"。
    /// user 側はそもそも空なので segments には現れない。
    func testUserSegmentsEmptyMakesOSSegmentsPB() {
        let displays = twoDisplays()
        let state = AppState(displays: displays, userSegments: [])
        let m = RenderModel.derive(from: state)
        let osSegs = m.segments.filter { $0.source == "os" }
        let userSegs = m.segments.filter { $0.source == "user" }
        XCTAssertEqual(osSegs.count, 2)
        XCTAssertEqual(userSegs.count, 0)
        for s in osSegs { XCTAssertEqual(s.edgeType, "pb", "user が空なので os 側は PB") }
    }

    /// OS 非隣接 + userSegments でブリッジしたとき、user 側の edgeType は "bp"。
    func testUserSegmentBridgingNonAdjacentDisplaysYieldsBP() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        let user = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        let state = AppState(displays: [a, c], userSegments: user)
        let m = RenderModel.derive(from: state)
        XCTAssertEqual(m.segments.filter { $0.source == "os" }.count, 0, "OS 隣接がないので os セグメントは無い")
        let userSegs = m.segments.filter { $0.source == "user" }
        XCTAssertEqual(userSegs.count, 2)
        for s in userSegs { XCTAssertEqual(s.edgeType, "bp", "OS 通過なし + 仮想通過ありは BP") }
    }

    // ==================
    // (3) キャリブレーション編集中の表示 (candidatePose の反映)
    // ==================

    /// dragStart → dragMove で candidatePose が入ると、physicalBounds は candidatePose を反映する。
    /// 元の pose (poseTranslateMm) は変わらず、candidatePoseTranslateMm 側に反映が現れる。
    /// draggingDisplayId / isDragging も同時に立つ。
    func testDragMoveCandidatePoseIsReflectedInPhysicalBoundsAndFlags() {
        var state = AppState(displays: twoDisplays(), userSegments: [])
        (state, _) = Store.reduce(state, .calibration(.dragStart(displayId: "A")))
        let candidate = DisplayPose(translate: PhysicalPoint(x: 300, y: 200), scaleX: 1, scaleY: 1)
        (state, _) = Store.reduce(state, .calibration(.dragMove(displayId: "A", candidatePose: candidate)))

        let m = RenderModel.derive(from: state)
        XCTAssertEqual(m.draggingDisplayId, "A")
        guard let a = m.displays.first(where: { $0.id == "A" }) else { return XCTFail("A missing") }
        XCTAssertTrue(a.isDragging)
        XCTAssertEqual(a.candidatePoseTranslateMm, RenderModel.Point(x: 300, y: 200))
        // 確定 pose 側は identity のまま (candidate はまだ未 commit)
        XCTAssertEqual(a.poseTranslateMm, RenderModel.Point(x: 0, y: 0))
        // physicalBounds は candidate 適用済み: translate=(300,200), scale=1 なので (300..2220, 200..1280)
        XCTAssertEqual(a.physicalBounds.minX, 300, accuracy: 1e-9)
        XCTAssertEqual(a.physicalBounds.minY, 200, accuracy: 1e-9)
        XCTAssertEqual(a.physicalBounds.maxX, 300 + 1920, accuracy: 1e-9)
        XCTAssertEqual(a.physicalBounds.maxY, 200 + 1080, accuracy: 1e-9)
        // ドラッグしていない B は元のまま
        guard let b = m.displays.first(where: { $0.id == "B" }) else { return XCTFail("B missing") }
        XCTAssertFalse(b.isDragging)
        XCTAssertNil(b.candidatePoseTranslateMm)
    }

    /// commit で candidate が確定 pose に取り込まれ、次の RenderModel では poseTranslateMm が更新される。
    /// candidatePoseTranslateMm / draggingDisplayId は idle 化でクリアされる。
    func testCommitPromotesCandidatePoseToConfirmedAndClearsEditingState() {
        var state = AppState(displays: twoDisplays(), userSegments: [])
        (state, _) = Store.reduce(state, .calibration(.dragStart(displayId: "A")))
        (state, _) = Store.reduce(state, .calibration(.dragMove(
            displayId: "A",
            candidatePose: DisplayPose(translate: PhysicalPoint(x: 50, y: 0), scaleX: 1, scaleY: 1))))
        (state, _) = Store.reduce(state, .calibration(.commit))

        let m = RenderModel.derive(from: state)
        XCTAssertNil(m.draggingDisplayId)
        guard let a = m.displays.first(where: { $0.id == "A" }) else { return XCTFail("A missing") }
        XCTAssertFalse(a.isDragging)
        XCTAssertNil(a.candidatePoseTranslateMm)
        XCTAssertEqual(a.poseTranslateMm, RenderModel.Point(x: 50, y: 0), "commit で candidate が確定に昇格")
    }

    // ==================
    // (4) Codable ラウンドトリップ
    // ==================

    /// RenderModel は JS 側へ JSON で渡すので、Encodable/Decodable の対称性を担保する。
    /// キー名 (camelCase) の互換を含めた同値ラウンドトリップで固定する。
    func testCodableRoundTripPreservesAllFields() throws {
        var state = AppState.initial(displays: twoDisplays())
        (state, _) = Store.reduce(state, .calibration(.dragStart(displayId: "A")))
        (state, _) = Store.reduce(state, .calibration(.dragMove(
            displayId: "A",
            candidatePose: DisplayPose(translate: PhysicalPoint(x: 10, y: 20), scaleX: 1, scaleY: 1))))

        let m = RenderModel.derive(from: state)
        let data = try JSONEncoder().encode(m)
        let restored = try JSONDecoder().decode(RenderModel.self, from: data)
        XCTAssertEqual(m, restored)
    }
}
