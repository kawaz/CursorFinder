// reconcile 純関数のテスト (DR-0007 決定 7)
import XCTest
@testable import LaserGuideCore

final class ReconcileTests: XCTestCase {

    /// persisted が nil (初回起動、永続設定なし) の場合、全 display が「新規」として扱われ、
    /// userSegments は osPassSegments のコピーで初期化される (AppState.initial と同じ既定、
    /// DR-0006 決定 5)。pose は全て恒等。inactiveUserSegments は空。
    func testReconcileWithNilPersistedTreatsAllDisplaysAsNewWithOSCopy() {
        let snapshots = [
            DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
            DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
        ]
        let result = Reconcile.reconcile(persisted: nil, currentSnapshots: snapshots)

        XCTAssertEqual(result.displays.map(\.pose), [.identity, .identity])
        XCTAssertFalse(result.userSegments.isEmpty, "新規構成は osPassSegments のコピーで初期化される")
        XCTAssertTrue(result.inactiveUserSegments.isEmpty)
    }

    /// 保存済み pose が hardwareId 一致で正しく適用されること (解像度が同じでもキャリブレーション
    /// が保持される、DR-0007 決定 1 の核心)。
    func testReconcileAppliesPersistedPoseByMatchingHardwareId() {
        let calibratedPose = DisplayPose(translate: PhysicalPoint(x: 500, y: 300), scaleX: 0.25, scaleY: 0.24)
        let persisted = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(hardwareId: "A", pose: calibratedPose, userSegments: []),
        ])
        let snapshots = [
            DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
        ]
        let result = Reconcile.reconcile(persisted: persisted, currentSnapshots: snapshots)

        XCTAssertEqual(result.displays.first?.pose, calibratedPose)
    }

    /// 既存 (対応先が今も接続中) の hardwareId の userSegments はそのまま引き継がれ、
    /// 新規に現れたモニタが無いので os コピーの自動追加も起きない (ユーザの明示編集を保護する、
    /// Store.reduceDisplayConfigurationChanged と同じ規律)。
    func testReconcileKeepsExistingUserSegmentsWithoutAddingOSCopyWhenNoNewDisplay() {
        let userSeg = PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 100, logicalEnd: 900, pairedSegmentId: "u-B")
        let userSegPaired = PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 100, logicalEnd: 900, pairedSegmentId: "u-A")
        let persisted = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(hardwareId: "A", pose: .identity, userSegments: [userSeg]),
            PersistedDisplayV3(hardwareId: "B", pose: .identity, userSegments: [userSegPaired]),
        ])
        let snapshots = [
            DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
            DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
        ]
        let result = Reconcile.reconcile(persisted: persisted, currentSnapshots: snapshots)

        XCTAssertEqual(Set(result.userSegments), Set([userSeg, userSegPaired]),
                        "既存モニタ同士は保存済み userSegments をそのまま引き継ぎ、os コピーを追加しない")
    }

    /// 保存済みだが現在の構成に存在しない hardwareId の userSegments は削除されず、
    /// inactiveUserSegments へ分離して保持される (決定 7: モニタを一時的に外しただけで
    /// 設定が消える体験を避ける)。通常の userSegments には含まれない。
    func testReconcileMarksSegmentsOfDisappearedDisplayAsInactive() {
        let goneSeg = PassSegment(id: "u-gone", displayId: "GONE", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-gone-pair")
        let persisted = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(hardwareId: "GONE", pose: .identity, userSegments: [goneSeg]),
        ])
        // 現在の接続構成には GONE が含まれない (モニタが一時的に外れた想定)。
        let snapshots = [
            DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
        ]
        let result = Reconcile.reconcile(persisted: persisted, currentSnapshots: snapshots)

        XCTAssertEqual(result.inactiveUserSegments, [goneSeg])
        XCTAssertFalse(result.userSegments.contains(goneSeg), "対応先を失った segment は現役 userSegments に含めない")
        XCTAssertFalse(result.displays.contains { $0.id == "GONE" }, "GONE は現在の snapshot に無いので displays にも現れない")
        XCTAssertEqual(result.displays.map(\.id), ["A"], "現在接続中の A のみが displays に現れる")
    }

    /// 新規に現れたモニタが絡む隣接ペアだけ os コピーが追加され、既存モニタ同士の隣接
    /// (ユーザが既に PB へ倒した可能性がある) には手を出さない。testDisplayConfigurationChangedAddsOSCopyOnlyForNewlyAppearedDisplays
    /// (StoreReduceTests.swift) と同じ仕様輪郭を reconcile 経路でも固定する。
    func testReconcileAddsOSCopyOnlyForNewlyAppearedDisplayPairs() {
        // 既存 A: 保存済み userSegments 空 (ユーザが A-B 間を明示的に PB 化した状態を模す)。
        let persisted = PersistedWorkspaceV3(displays: [
            PersistedDisplayV3(hardwareId: "A", pose: .identity, userSegments: []),
        ])
        // 現在の構成: A (既存) はそのまま、B (既存 hardwareId 一覧に無い = 新規) が A に隣接して追加。
        let snapshots = [
            DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
            DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
        ]
        let result = Reconcile.reconcile(persisted: persisted, currentSnapshots: snapshots)

        XCTAssertTrue(
            result.userSegments.contains { $0.displayId == "A" && $0.side == .right },
            "新規検出された B との隣接は os コピーとして追加される")
        XCTAssertTrue(
            result.userSegments.contains { $0.displayId == "B" && $0.side == .left },
            "os コピーはペア両側とも追加される (片側だけの非対称状態を作らない)")
    }
}
