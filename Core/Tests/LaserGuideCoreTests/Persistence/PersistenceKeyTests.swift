// キー設計のテスト (DR-0007 決定 1, 2, 3, 5)
import XCTest
@testable import LaserGuideCore

final class PersistenceKeyTests: XCTestCase {

    // ==================
    // v3 workspace key (決定 1, 2)
    // ==================

    /// key prefix が `LaserGuide.v3.` 系であること (決定 2)。
    func testWorkspaceKeyUsesV3Prefix() {
        let key = PersistenceKeyV3.workspaceKey(hardwareIds: ["1-2-3"])
        XCTAssertTrue(key.hasPrefix("LaserGuide.v3.workspace."))
    }

    /// hardwareId の列挙順が違っても同一構成なら同一キーになること (決定 1: sorted 結合)。
    /// 同型モニタの接続順序が変わっただけでキャリブレーションが迷子にならないための仕様。
    func testWorkspaceKeyIsOrderIndependent() {
        let keyAB = PersistenceKeyV3.workspaceKey(hardwareIds: ["A", "B"])
        let keyBA = PersistenceKeyV3.workspaceKey(hardwareIds: ["B", "A"])
        XCTAssertEqual(keyAB, keyBA)
    }

    /// resolution/backingScaleFactor に相当する情報がキー生成 API に存在しないこと自体が
    /// 「モニタ同一性は hardwareId のみ」という決定 1 の型レベルの保証だが、機能テストとしては
    /// 異なる hardwareId 集合が異なるキーになることを固定する (衝突しないことの最低限の保証)。
    func testDifferentHardwareIdSetsProduceDifferentKeys() {
        let key1 = PersistenceKeyV3.workspaceKey(hardwareIds: ["A"])
        let key2 = PersistenceKeyV3.workspaceKey(hardwareIds: ["A", "B"])
        XCTAssertNotEqual(key1, key2)
    }

    // ==================
    // v1 key 判定 (決定 3, 5)
    // ==================

    /// v1 実物キー形式 (CalibrationDataManager.swift:42 `calibrationKeyPrefix + configurationKey`)
    /// を永続設定キーとして認識する。
    func testV1PersistentConfigKeyIsRecognized() {
        XCTAssertTrue(PersistenceKeyV1.isPersistentConfigKey("LaserGuide.Calibration.config_1-2-3"))
        XCTAssertFalse(PersistenceKeyV1.isTemporaryKey("LaserGuide.Calibration.config_1-2-3"))
    }

    /// v1 実物の temporary キー形式 (CalibrationDataManager.swift:51) を temporary として認識し、
    /// 永続設定キーとしては扱わない (決定 5: プレビュー方式廃止、migration 対象外で読み捨てる)。
    func testV1TemporaryKeyIsRecognizedAndExcludedFromPersistentConfig() {
        XCTAssertTrue(PersistenceKeyV1.isTemporaryKey("LaserGuide.Calibration.config_1-2-3.temporary"))
        XCTAssertFalse(PersistenceKeyV1.isPersistentConfigKey("LaserGuide.Calibration.config_1-2-3.temporary"))
    }

    /// v1 prefix を持たない無関係なキー (v3 キーや他アプリのキー) はどちらの判定にも該当しない。
    func testUnrelatedKeysAreNotClassifiedAsV1() {
        XCTAssertFalse(PersistenceKeyV1.isPersistentConfigKey("LaserGuide.v3.workspace.A"))
        XCTAssertFalse(PersistenceKeyV1.isTemporaryKey("LaserGuide.v3.workspace.A"))
        XCTAssertFalse(PersistenceKeyV1.isPersistentConfigKey("SomeOtherApp.settings"))
    }
}
