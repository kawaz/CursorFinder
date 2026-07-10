// v1 → v3 migration のテスト (DR-0007 決定 3)
//
// v1 実スキーマは LaserGuide.v1.backup/Models/DisplayIdentifier.swift を正本とする
// (V1Schema.swift 冒頭コメントに file:line 引用あり)。fixture は V1DisplayConfiguration を
// Swift 値として組み立てて JSONEncoder でエンコードする (v1 が実際に書き出す形式そのもの、
// CalibrationDataManager.swift:43 `JSONEncoder().encode(configuration)` と同じデフォルト設定)。
import XCTest
@testable import LaserGuideCore

final class V1MigrationTests: XCTestCase {

    private let vendorA: UInt32 = 100, modelA: UInt32 = 200, serialA: UInt32 = 1
    private let vendorB: UInt32 = 100, modelB: UInt32 = 200, serialB: UInt32 = 2

    private var hardwareIdA: String { "\(vendorA)-\(modelA)-\(serialA)" }
    private var hardwareIdB: String { "\(vendorB)-\(modelB)-\(serialB)" }

    /// v1 のモニタ 1 台構成 (隣接 = edgeZone 無し) を migrate すると、pose の translate は
    /// DR-0005 (2026-07-10 追記) の Y 軸反転補正 `y_down = -(position.y + size.height)` を経て
    /// v3 (y-down) の値になり、userSegments は空になること。
    ///
    /// position=(10, 20), size=(500, 300) (bottom-left, y-up) の場合:
    /// top edge の y-up 座標 = 20 + 300 = 320、反転して y_down = -320。x は補正不要でそのまま。
    func testMigrateSingleDisplayWithNoEdgeZonesProducesEmptyUserSegments() throws {
        let v1Config = V1DisplayConfiguration(
            displays: [
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorA, modelID: modelA, serialNumber: serialA),
                    position: V1PhysicalPoint(x: 10, y: 20), size: V1PhysicalSize(width: 500, height: 300)),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 0), edgeZones: [], edgeZonePairs: [])
        let data = try JSONEncoder().encode(v1Config)

        let result = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: [:])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.displays.count, 1)
        let display = try XCTUnwrap(result?.displays.first)
        XCTAssertEqual(display.hardwareId, hardwareIdA)
        XCTAssertEqual(display.pose.translate.x, 10, "x は左右反転がないため補正不要")
        XCTAssertEqual(display.pose.translate.y, -320, "y_down = -(20 + 300)")
        XCTAssertEqual(display.pose.scaleX, 1.0, "v1 は px 解像度を保存しないため scale は恒等の暫定値")
        XCTAssertEqual(display.pose.scaleY, 1.0)
        XCTAssertEqual(display.userSegments, [])
    }

    /// DR-0005 の Y 軸反転補正が「上下関係の意味」を保つことを固定する核心テスト。
    /// v1 (y-up) で上に配置されたモニス (position.y が大きい) は、v3 (y-down) でも
    /// 引き続き「上」(translate.y が小さい) でなければならない。符号だけ合わせて
    /// 上下関係が逆転していないか (最もありがちな反転バグ) をここで検出する。
    func testMigrateYAxisFlipPreservesTopBottomOrderingForStackedDisplays() throws {
        // v1 (y-up, bottom-left corner): bottomDisplay は y=0 (下)、topDisplay は y=300 (上、
        // bottomDisplay の真上に隙間なく積まれている想定: bottomDisplay.position.y + height == topDisplay.position.y)。
        let bottomDisplay = V1PhysicalDisplayLayout(
            identifier: V1DisplayIdentifier(vendorID: vendorA, modelID: modelA, serialNumber: serialA),
            position: V1PhysicalPoint(x: 0, y: 0), size: V1PhysicalSize(width: 500, height: 300))
        let topDisplay = V1PhysicalDisplayLayout(
            identifier: V1DisplayIdentifier(vendorID: vendorB, modelID: modelB, serialNumber: serialB),
            position: V1PhysicalPoint(x: 0, y: 300), size: V1PhysicalSize(width: 500, height: 200))
        let v1Config = V1DisplayConfiguration(
            displays: [bottomDisplay, topDisplay],
            timestamp: Date(timeIntervalSinceReferenceDate: 0), edgeZones: [], edgeZonePairs: [])
        let data = try JSONEncoder().encode(v1Config)

        let result = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: [:])
        let bottomPose = try XCTUnwrap(result?.displays.first { $0.hardwareId == hardwareIdA }?.pose)
        let topPose = try XCTUnwrap(result?.displays.first { $0.hardwareId == hardwareIdB }?.pose)

        // y-down (v3) では「上」ほど y が小さい。v1 で上だった topDisplay が
        // v3 でも bottomDisplay より y が小さい (= 上) ままであることを固定する。
        XCTAssertLessThan(topPose.translate.y, bottomPose.translate.y,
                           "v1 で上に配置されたモニタは v3 (y-down) でも y が小さい (上) 側でなければならない")
        // 具体値でも固定する: bottom は y_down = -(0+300) = -300、top は y_down = -(300+200) = -500。
        XCTAssertEqual(bottomPose.translate.y, -300)
        XCTAssertEqual(topPose.translate.y, -500)
    }

    /// v1 の 2 台構成 + A.right <-> B.left の edgeZonePair (0.25-0.75 の正規化区間) を、
    /// 現在の px サイズを与えて migrate すると、対応する PassSegment ペアが px 換算された
    /// logicalStart/logicalEnd で生成されること。
    func testMigrateTwoDisplaysWithEdgeZonePairConvertsNormalizedRangeToPixels() throws {
        let zoneA = V1EdgeZone(id: UUID(), displayId: hardwareIdA, edge: .right, rangeStart: 0.25, rangeEnd: 0.75)
        let zoneB = V1EdgeZone(id: UUID(), displayId: hardwareIdB, edge: .left, rangeStart: 0.25, rangeEnd: 0.75)
        let pair = V1EdgeZonePair(id: UUID(), sourceZoneId: zoneA.id, targetZoneId: zoneB.id)
        let v1Config = V1DisplayConfiguration(
            displays: [
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorA, modelID: modelA, serialNumber: serialA),
                    position: V1PhysicalPoint(x: 0, y: 0), size: V1PhysicalSize(width: 500, height: 300)),
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorB, modelID: modelB, serialNumber: serialB),
                    position: V1PhysicalPoint(x: 500, y: 0), size: V1PhysicalSize(width: 500, height: 300)),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            edgeZones: [zoneA, zoneB], edgeZonePairs: [pair])
        let data = try JSONEncoder().encode(v1Config)

        // A/B とも 1920x1080 の現在解像度と仮定 (right/left は縦 = height 基準で正規化されている)。
        let result = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: [
            hardwareIdA: V1CurrentPixelSize(width: 1920, height: 1080),
            hardwareIdB: V1CurrentPixelSize(width: 1920, height: 1080),
        ])

        let displayA = try XCTUnwrap(result?.displays.first { $0.hardwareId == hardwareIdA })
        let displayB = try XCTUnwrap(result?.displays.first { $0.hardwareId == hardwareIdB })
        XCTAssertEqual(displayA.userSegments.count, 1)
        XCTAssertEqual(displayB.userSegments.count, 1)

        let segA = try XCTUnwrap(displayA.userSegments.first)
        XCTAssertEqual(segA.side, .right)
        XCTAssertEqual(segA.logicalStart, 0.25 * 1080, accuracy: 1e-9)
        XCTAssertEqual(segA.logicalEnd, 0.75 * 1080, accuracy: 1e-9)

        let segB = try XCTUnwrap(displayB.userSegments.first)
        XCTAssertEqual(segB.side, .left)
        // pairedSegmentId の相互参照が壊れていないこと (対応セグメントを id で引ける)。
        XCTAssertEqual(segA.pairedSegmentId, segB.id)
        XCTAssertEqual(segB.pairedSegmentId, segA.id)
    }

    /// edgeZonePairs にどのペアからも参照されない孤立 zone (壊れた/片方だけ残った編集途中の
    /// データを想定) は、対応関係が組めないため migration 対象外として無視される。
    func testMigrateSkipsEdgeZoneNotReferencedByAnyPair() throws {
        let orphanZone = V1EdgeZone(id: UUID(), displayId: hardwareIdA, edge: .top, rangeStart: 0, rangeEnd: 1)
        let v1Config = V1DisplayConfiguration(
            displays: [
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorA, modelID: modelA, serialNumber: serialA),
                    position: V1PhysicalPoint(x: 0, y: 0), size: V1PhysicalSize(width: 500, height: 300)),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 0), edgeZones: [orphanZone], edgeZonePairs: [])
        let data = try JSONEncoder().encode(v1Config)

        let result = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: [
            hardwareIdA: V1CurrentPixelSize(width: 1920, height: 1080),
        ])
        XCTAssertEqual(result?.displays.first?.userSegments, [], "参照されない孤立 zone は migration 対象外")
    }

    /// 現在の px サイズが提供されないモニタが絡む edgeZonePair は、0-1 正規化区間を px へ
    /// 変換する材料が無いため migration をスキップする (crash や不正な 0 幅換算を避ける)。
    func testMigrateSkipsSegmentsWhenCurrentPixelSizeIsMissingForInvolvedDisplay() throws {
        let zoneA = V1EdgeZone(id: UUID(), displayId: hardwareIdA, edge: .right, rangeStart: 0, rangeEnd: 1)
        let zoneB = V1EdgeZone(id: UUID(), displayId: hardwareIdB, edge: .left, rangeStart: 0, rangeEnd: 1)
        let pair = V1EdgeZonePair(id: UUID(), sourceZoneId: zoneA.id, targetZoneId: zoneB.id)
        let v1Config = V1DisplayConfiguration(
            displays: [
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorA, modelID: modelA, serialNumber: serialA),
                    position: V1PhysicalPoint(x: 0, y: 0), size: V1PhysicalSize(width: 500, height: 300)),
                V1PhysicalDisplayLayout(
                    identifier: V1DisplayIdentifier(vendorID: vendorB, modelID: modelB, serialNumber: serialB),
                    position: V1PhysicalPoint(x: 500, y: 0), size: V1PhysicalSize(width: 500, height: 300)),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            edgeZones: [zoneA, zoneB], edgeZonePairs: [pair])
        let data = try JSONEncoder().encode(v1Config)

        // hardwareIdB の px サイズを与えない (B が未接続 or 情報欠落を模す)。
        let result = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: [
            hardwareIdA: V1CurrentPixelSize(width: 1920, height: 1080),
        ])
        XCTAssertEqual(result?.displays.first { $0.hardwareId == hardwareIdA }?.userSegments, [],
                        "対応先 B の px サイズが無いため A 側のセグメントも生成されない")
    }

    /// decode 不能な JSON (v1 データが壊れている/別スキーマ) は crash せず nil を返す。
    func testMigrateReturnsNilForUndecodableData() {
        let garbage = "{ \"not\": \"a v1 configuration\" }".data(using: .utf8)!
        XCTAssertNil(V1Migration.migrate(v1Data: garbage, currentPixelSizeByHardwareId: [:]))
    }
}
