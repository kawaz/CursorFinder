// PersistenceBoot の起動時 load フローと canonicalize ヘルパのテスト (DR-0007 決定 1-5)。
//
// - load フローの 3 分岐 (v3 発見 / v1 → migration / どちらも無い) を InMemoryKeyValueStore で固定
// - v1 3-part hardwareId → v3 4-part hardwareId への canonicalize (衝突ケース含む)
// - scale 上書き / translate 保存値の尊重 (DR-0005 決定 2)
// - v1 の `.temporary` プレビューキーが常に削除されること (DR-0007 決定 5)
import XCTest
@testable import LaserGuideDev
import LaserGuideCore

final class PersistenceBootTests: XCTestCase {

    // MARK: - fixture helpers

    /// v3 hardwareId ("vendor-model-serial-unit")。
    private func hwId(_ v: UInt32, _ m: UInt32, _ s: UInt32, _ u: UInt32) -> String {
        "\(v)-\(m)-\(s)-\(u)"
    }

    /// snapshot 1 枚 (id 指定、bounds は 1920x1080)。
    private func snap(_ id: String, x: Double = 0, y: Double = 0,
                      width: Double = 1920, height: Double = 1080) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id,
            logicalBounds: LogicalRect(minX: x, minY: y, maxX: x + width, maxY: y + height))
    }

    // MARK: - noPersistence 経路

    /// 空 store + 現構成のみ渡すと noPersistence が返ること (初回起動時、AppDelegate は
    /// AppState.initial で os コピー初期化に倒す)。
    func testLoadWithEmptyStoreReturnsNoPersistence() {
        let store = InMemoryKeyValueStore()
        let currentId = hwId(100, 200, 1, 0)
        let result = PersistenceBoot.loadAndPersist(
            store: store,
            currentSnapshots: [snap(currentId)],
            currentScaleByHardwareId: [currentId: (0.25, 0.25)],
            currentPixelSizeByHardwareId: [currentId: V1CurrentPixelSize(width: 1920, height: 1080)])
        XCTAssertEqual(result.outcome, .noPersistence)
        XCTAssertFalse(result.didMigrateFromV1)
        XCTAssertEqual(result.temporaryKeysDeleted, [])
        // store には何も書かれない (v3 key も v1 key も未存在)。
        XCTAssertEqual(store.allKeys(), [])
    }

    // MARK: - v3 保存経路

    /// v3 key に有効な JSON があれば usedPersisted 経路で読み込まれ、scale は現構成の値で
    /// 上書き、translate は保存値をそのまま尊重されること。
    func testLoadFromV3KeyOverridesScaleButKeepsTranslate() throws {
        let store = InMemoryKeyValueStore()
        let currentId = hwId(100, 200, 1, 0)
        // 保存 pose: translate=(50, -60), scale は古い暫定値 (0.5)。
        let persisted = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(
                hardwareId: currentId,
                pose: DisplayPose(translate: PhysicalPoint(x: 50, y: -60),
                                  scaleX: 0.5, scaleY: 0.5),
                userSegments: [])
        ])
        let key = PersistenceKeyV3.workspaceKey(hardwareIds: [currentId])
        store.set(try persisted.encoded(), forKey: key)

        let result = PersistenceBoot.loadAndPersist(
            store: store,
            currentSnapshots: [snap(currentId)],
            currentScaleByHardwareId: [currentId: (0.25, 0.30)],
            currentPixelSizeByHardwareId: [currentId: V1CurrentPixelSize(width: 1920, height: 1080)])
        guard case let .usedPersisted(reconciled) = result.outcome else {
            XCTFail("expected usedPersisted, got \(result.outcome)"); return
        }
        XCTAssertFalse(result.didMigrateFromV1)
        XCTAssertEqual(reconciled.displays.count, 1)
        let d = try XCTUnwrap(reconciled.displays.first)
        XCTAssertEqual(d.pose.translate.x, 50, "translate は保存値を尊重")
        XCTAssertEqual(d.pose.translate.y, -60)
        XCTAssertEqual(d.pose.scaleX, 0.25, "scale は現構成で上書き")
        XCTAssertEqual(d.pose.scaleY, 0.30)
    }

    // MARK: - v1 migration 経路

    /// v1 実スキーマの JSON リテラルを組む (V1Schema.swift の型は Core 内部 non-public のため
    /// App test では触れない、直接 JSON を書いてバイト列を作る)。
    /// timestamp は JSONEncoder default (`.deferredToDate`) の Double 表現 (referenceDate 起点秒)。
    private func v1DisplayConfigJSON(vendor: UInt32, model: UInt32, serial: UInt32,
                                     posX: Double, posY: Double,
                                     width: Double, height: Double) -> Data {
        let text = """
            {
              "displays": [
                {
                  "identifier": {"vendorID": \(vendor), "modelID": \(model), "serialNumber": \(serial)},
                  "position": {"x": \(posX), "y": \(posY)},
                  "size": {"width": \(width), "height": \(height)}
                }
              ],
              "timestamp": 0,
              "edgeZones": [],
              "edgeZonePairs": []
            }
            """
        return Data(text.utf8)
    }

    /// v3 が無く v1 の非 temporary key があれば V1Migration が走り、canonicalize 後に v3 key へ
    /// 保存されること。3-part の v1 hardwareId は現構成の 4-part v3 hardwareId に書き換わる。
    func testLoadMigratesFromV1WhenV3AbsentAndPersistsToV3Key() throws {
        let store = InMemoryKeyValueStore()
        let v3Id = hwId(100, 200, 1, 0)
        let v1Id = "100-200-1"  // v3Id の "unit" を落とした 3-part

        // v1 実スキーマで書かれた JSON。position=(10, 20), size=(500, 300) mm、EdgeZone 無し。
        let v1Data = v1DisplayConfigJSON(vendor: 100, model: 200, serial: 1,
                                          posX: 10, posY: 20, width: 500, height: 300)
        // v1 が書く実キー "LaserGuide.Calibration.config_<sorted identifiers>" を模擬。
        let v1Key = PersistenceKeyV1.keyPrefix + "config_" + v1Id
        store.set(v1Data, forKey: v1Key)

        let result = PersistenceBoot.loadAndPersist(
            store: store,
            currentSnapshots: [snap(v3Id)],
            currentScaleByHardwareId: [v3Id: (0.25, 0.30)],
            currentPixelSizeByHardwareId: [v3Id: V1CurrentPixelSize(width: 1920, height: 1080)])
        XCTAssertTrue(result.didMigrateFromV1)
        guard case let .usedPersisted(reconciled) = result.outcome else {
            XCTFail("expected usedPersisted, got \(result.outcome)"); return
        }
        // canonicalize 済みなので display.hardwareId は 4-part の v3Id
        XCTAssertEqual(reconciled.displays.count, 1)
        let d = try XCTUnwrap(reconciled.displays.first)
        XCTAssertEqual(d.id, v3Id, "3-part → 4-part canonicalize が走る")
        // v1 y 反転補正: y_down = -(20 + 300) = -320
        XCTAssertEqual(d.pose.translate.y, -320)
        XCTAssertEqual(d.pose.translate.x, 10)
        // scale は現構成で上書き
        XCTAssertEqual(d.pose.scaleX, 0.25)
        XCTAssertEqual(d.pose.scaleY, 0.30)

        // v3 key に保存されている (次回起動から v3 経路で読める)
        let v3Key = PersistenceKeyV3.workspaceKey(hardwareIds: [v3Id])
        XCTAssertNotNil(store.data(forKey: v3Key))
    }

    // MARK: - `.temporary` key の掃除

    /// v3 経由でも v1 経由でも none でも、v1 の `.temporary` プレビューキーは常に削除されること
    /// (DR-0007 決定 5: プレビュー永続化廃止)。
    func testTemporaryKeysAreDeletedInAllOutcomes() throws {
        let currentId = hwId(100, 200, 1, 0)
        let tempKey = PersistenceKeyV1.keyPrefix + "config_100-200-1" + PersistenceKeyV1.temporarySuffix

        for scenario in ["none", "v3", "v1"] {
            let store = InMemoryKeyValueStore()
            store.set(Data([0x00]), forKey: tempKey)  // dummy content
            switch scenario {
            case "v3":
                let persisted = PersistedWorkspaceV3(displays: [
                    PersistedDisplayV3(
                        hardwareId: currentId, pose: .identity, userSegments: [])
                ])
                store.set(try persisted.encoded(),
                    forKey: PersistenceKeyV3.workspaceKey(hardwareIds: [currentId]))
            case "v1":
                store.set(v1DisplayConfigJSON(vendor: 100, model: 200, serial: 1,
                                              posX: 0, posY: 0, width: 500, height: 300),
                    forKey: PersistenceKeyV1.keyPrefix + "config_100-200-1")
            default: break
            }
            let result = PersistenceBoot.loadAndPersist(
                store: store,
                currentSnapshots: [snap(currentId)],
                currentScaleByHardwareId: [currentId: (0.25, 0.25)],
                currentPixelSizeByHardwareId: [currentId: V1CurrentPixelSize(width: 1920, height: 1080)])
            XCTAssertEqual(result.temporaryKeysDeleted, [tempKey],
                "scenario=\(scenario) で temporary key が削除される")
            XCTAssertNil(store.data(forKey: tempKey),
                "scenario=\(scenario) で store 側からも消える")
        }
    }

    // MARK: - canonicalize ヘルパ単体

    /// buildV1PixelSizeMap: v3 4-part id を 3-part にマップしてキーにする。衝突は最初の一件を優先。
    func testBuildV1PixelSizeMapStripsUnitAndKeepsFirstOnCollision() {
        let m = PersistenceBoot.buildV1PixelSizeMap([
            "100-200-1-0": V1CurrentPixelSize(width: 100, height: 200),
            "100-200-2-0": V1CurrentPixelSize(width: 300, height: 400),
        ])
        XCTAssertEqual(m["100-200-1"]?.width, 100)
        XCTAssertEqual(m["100-200-2"]?.width, 300)
    }

    /// canonicalizeV1ToV3HardwareIds: 3-part hardwareId は現構成の 4-part id に書き換わる。
    /// 4-part id は現構成に不在でも drop せず、そのまま維持する (v3 で書かれた保存を混ぜて
    /// 読める可能性を残す設計)。3-part で対応不能な id は drop する。
    func testCanonicalizeRewritesThreePartIdsToFourPartAndDropsUnresolved() {
        let v3Id = hwId(100, 200, 1, 0)
        let v1Id = "100-200-1"
        let migrated = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(
                hardwareId: v1Id,
                pose: DisplayPose(translate: PhysicalPoint(x: 1, y: 2), scaleX: 1, scaleY: 1),
                userSegments: [
                    PassSegment(id: "seg1", displayId: v1Id, side: .top,
                                logicalStart: 0, logicalEnd: 100, pairedSegmentId: "seg2"),
                ]),
            // 現構成に無い 3-part id (v3 に対応するモニタが繋がっていない) は drop
            PersistedDisplayV3(
                hardwareId: "999-999-9", pose: .identity, userSegments: []),
        ])
        let out = PersistenceBoot.canonicalizeV1ToV3HardwareIds(
            migrated, currentSnapshots: [snap(v3Id)])
        XCTAssertEqual(out.displays.count, 1, "現構成に居ない 3-part id の display は drop")
        let d = out.displays[0]
        XCTAssertEqual(d.hardwareId, v3Id, "3-part → 4-part 書き換え")
        XCTAssertEqual(d.userSegments.first?.displayId, v3Id, "segment.displayId も書き換わる")
    }

    /// canonicalize は同モデル 2 枚が同じ 3-part に潰れる衝突ケースでは対応表から除外する。
    /// v1 側で既に区別できていない前提のため、片方を勝手に採用せず両方 drop する挙動を固定。
    func testCanonicalizeDropsBothOnV1IdCollision() {
        let v3IdA = hwId(100, 200, 1, 0)
        let v3IdB = hwId(100, 200, 1, 1)  // A と同じ 3-part、unit だけ違う
        XCTAssertEqual(v3IdA.split(separator: "-").prefix(3).joined(separator: "-"), "100-200-1")
        XCTAssertEqual(v3IdB.split(separator: "-").prefix(3).joined(separator: "-"), "100-200-1")

        let migrated = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(hardwareId: "100-200-1", pose: .identity, userSegments: []),
        ])
        let out = PersistenceBoot.canonicalizeV1ToV3HardwareIds(
            migrated, currentSnapshots: [snap(v3IdA), snap(v3IdB)])
        XCTAssertEqual(out.displays.count, 0,
            "3-part 衝突: 対応表から除外、該当 display は drop (勝手に片方を採用しない)")
    }

    // MARK: - persist 書き込み

    /// persist は workspace の hardwareId 集合から v3 key を作って書き込む。
    /// 空 store に書けば workspace が復元可能な形で読める (次回起動での自動 load を模擬)。
    func testPersistWritesToV3KeyAndIsReadable() throws {
        let store = InMemoryKeyValueStore()
        let id = hwId(100, 200, 1, 0)
        let workspace = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(
                hardwareId: id,
                pose: DisplayPose(translate: PhysicalPoint(x: 7, y: 8),
                                  scaleX: 0.2, scaleY: 0.2),
                userSegments: [])
        ])
        PersistenceBoot.persist(workspace, to: store)
        let key = PersistenceKeyV3.workspaceKey(hardwareIds: [id])
        let data = try XCTUnwrap(store.data(forKey: key))
        let readback = try XCTUnwrap(PersistedWorkspaceV3.decodeTolerantly(data))
        XCTAssertEqual(readback, workspace)
    }
}
