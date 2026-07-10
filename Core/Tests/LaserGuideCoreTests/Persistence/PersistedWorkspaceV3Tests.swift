// PersistedWorkspaceV3 の encode/decode round-trip + 前方互換 (DR-0007 決定 2, 6)
import XCTest
@testable import LaserGuideCore

final class PersistedWorkspaceV3Tests: XCTestCase {

    /// 素朴な 1 モニタ構成の encode → decode で元の値が完全に復元されること。
    /// スキーマの正本が Swift Codable 型に一元化されている (決定 6) ことの最も基本的な保証。
    func testSingleDisplayRoundTrip() throws {
        let workspace = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(
                hardwareId: "1-2-3",
                pose: DisplayPose(translate: PhysicalPoint(x: 100, y: 50), scaleX: 0.25, scaleY: 0.26),
                userSegments: [
                    PassSegment(id: "u-A", displayId: "1-2-3", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-B"),
                ]
            ),
        ])
        let data = try workspace.encoded()
        let decoded = PersistedWorkspaceV3.decodeTolerantly(data)
        XCTAssertEqual(decoded, workspace)
    }

    /// 複数モニタ + 複数 userSegments でも round-trip が保たれること (1 サンプルに頼らない)。
    func testMultiDisplayRoundTrip() throws {
        let workspace = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(
                hardwareId: "A", pose: .identity,
                userSegments: [
                    PassSegment(id: "u-A-right", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-B-left"),
                ]),
            PersistedDisplayV3(
                hardwareId: "B", pose: DisplayPose(translate: PhysicalPoint(x: -500, y: 0), scaleX: 0.5, scaleY: 0.5),
                userSegments: [
                    PassSegment(id: "u-B-left", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A-right"),
                ]),
        ])
        let data = try workspace.encoded()
        let decoded = PersistedWorkspaceV3.decodeTolerantly(data)
        XCTAssertEqual(decoded, workspace)
    }

    /// version フィールドが currentVersion と一致することを新規保存時に固定する
    /// (DR-0007 決定 2: 将来 migration を一方向の変換関数として書けるようにする前提)。
    func testNewWorkspaceUsesCurrentVersion() {
        let workspace = PersistedWorkspaceV3(displays: [])
        XCTAssertEqual(workspace.version, PersistedWorkspaceV3.currentVersion)
    }

    /// 未知の追加フィールドを持つ JSON (将来 version が新フィールドを足した想定) でも
    /// decode 自体はクラッシュせず成功する前方互換性 (DR-0007 「未知 version フィールドを無視」)。
    /// Codable の既定動作 (未知キーの無視) がこの要求を満たすことを固定する。
    func testDecodeToleratesUnknownAdditionalFields() {
        let json = """
        {
          "version": 3,
          "displays": [
            {
              "hardwareId": "A",
              "pose": {"translate": {"x": 0, "y": 0}, "scaleX": 1, "scaleY": 1},
              "userSegments": [],
              "futureFieldNotYetKnown": "some-value"
            }
          ],
          "anotherFutureTopLevelField": 42
        }
        """.data(using: .utf8)!
        let decoded = PersistedWorkspaceV3.decodeTolerantly(json)
        XCTAssertNotNil(decoded, "未知の追加フィールドがあっても decode は成功するべき")
        XCTAssertEqual(decoded?.displays.first?.hardwareId, "A")
    }

    /// このビルドの currentVersion より新しい version 番号は「まだ意味を知らないデータ」として
    /// 無視 (nil) を返す。クラッシュではなく安全側にフォールバックする前方互換性。
    func testDecodeIgnoresFutureVersionNumberInsteadOfCrashing() {
        let json = """
        {
          "version": 999,
          "displays": []
        }
        """.data(using: .utf8)!
        XCTAssertNil(PersistedWorkspaceV3.decodeTolerantly(json), "未来の version は無視されるべき (nil)")
    }

    /// 壊れた JSON (必須フィールド欠落) は crash せず nil を返す。
    func testDecodeReturnsNilForCorruptedJSON() {
        let json = "{ \"not\": \"a valid workspace\" }".data(using: .utf8)!
        XCTAssertNil(PersistedWorkspaceV3.decodeTolerantly(json))
    }

    /// DisplayPose の precondition (scale > 0) を壊すデータを decode しようとしても、
    /// crash ではなく decode 失敗 (nil) になること。改ざん・破損データからの保護。
    func testDecodeRejectsNonPositiveScaleWithoutCrashing() {
        let json = """
        {
          "version": 3,
          "displays": [
            {
              "hardwareId": "A",
              "pose": {"translate": {"x": 0, "y": 0}, "scaleX": 0, "scaleY": 1},
              "userSegments": []
            }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertNil(PersistedWorkspaceV3.decodeTolerantly(json), "scaleX <= 0 のデータは crash せず nil を返すべき")
    }
}
