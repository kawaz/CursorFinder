// reconcile 純関数 (DR-0007 決定 7)
//
// 保存済み workspace + 現在の DisplaySnapshot 列 → 適用結果。
// - hardwareId が一致した display には保存済み pose/userSegments を適用する
// - 対応先を失った (現在の構成に存在しない hardwareId の) userSegments は削除せず
//   inactiveUserSegments として分離保持する (UI 側で可視化するための診断情報)
// - 新規 display (保存済み workspace に無い hardwareId) は userSegments を
//   osPassSegments のコピーで初期化する (DR-0006 決定 5 と同じ既定、Store.swift の
//   reduceDisplayConfigurationChanged と同じ規律を Reconcile 側で独立に再現する。
//   Store.swift は書き込み範囲外のため、ロジックの共有ではなく意図的な重複)
import Foundation

public struct ReconcileResult: Equatable, Sendable {
    public var displays: [Display]
    public var userSegments: [PassSegment]
    /// 対応する現在の display を失った userSegments (削除されず保持、決定 7)。
    public var inactiveUserSegments: [PassSegment]

    public init(displays: [Display], userSegments: [PassSegment], inactiveUserSegments: [PassSegment]) {
        self.displays = displays
        self.userSegments = userSegments
        self.inactiveUserSegments = inactiveUserSegments
    }
}

public enum Reconcile {
    /// - Parameters:
    ///   - persisted: 保存済み workspace。永続設定がまだ無い初回起動なら nil を渡す
    ///     (AppState.initial 相当: 全 display が「新規」として os コピーの userSegments を持つ)。
    ///   - currentSnapshots: OS から報告された現在のモニタ構成。
    public static func reconcile(
        persisted: PersistedWorkspaceV3?, currentSnapshots: [DisplaySnapshot]
    ) -> ReconcileResult {
        let persistedByHardwareId = Dictionary(
            uniqueKeysWithValues: (persisted?.displays ?? []).map { ($0.hardwareId, $0) })

        let displays = currentSnapshots.map { snapshot -> Display in
            let pose = persistedByHardwareId[snapshot.id]?.pose ?? .identity
            return Display(id: snapshot.id, logicalBounds: snapshot.logicalBounds, pose: pose)
        }

        let currentIds = Set(currentSnapshots.map(\.id))
        let persistedIds = Set(persistedByHardwareId.keys)
        let newlyAppearedIds = currentIds.subtracting(persistedIds)
        let goneIds = persistedIds.subtracting(currentIds)

        // 対応先が現在も存在する userSegments はそのまま引き継ぐ。
        var reconciledUserSegments: [PassSegment] = persistedByHardwareId
            .filter { currentIds.contains($0.key) }
            .flatMap { $0.value.userSegments }

        // 対応先を失った userSegments は削除せず inactive として分離保持する (決定 7)。
        let inactiveUserSegments: [PassSegment] = persistedByHardwareId
            .filter { goneIds.contains($0.key) }
            .flatMap { $0.value.userSegments }

        // 新規 display が絡むペアのみ os コピーを追加する。既存モニタ同士の隣接には手を出さず、
        // ユーザが明示的に PB へ倒した可能性のある userSegments を上書きしない
        // (Store.reduceDisplayConfigurationChanged と同じ理由、AppState.swift 冒頭コメント参照)。
        if !newlyAppearedIds.isEmpty {
            let allOSSegments = Adjacency.detectOSPassSegments(displays)
            let osSegmentsById = Dictionary(uniqueKeysWithValues: allOSSegments.map { ($0.id, $0) })
            let existingSegmentIds = Set(reconciledUserSegments.map(\.id))
            let osSegmentsInvolvingNewDisplays = allOSSegments.filter { seg in
                guard !existingSegmentIds.contains(seg.id) else { return false }
                let pairedInvolvesNew = osSegmentsById[seg.pairedSegmentId]
                    .map { newlyAppearedIds.contains($0.displayId) } ?? false
                return newlyAppearedIds.contains(seg.displayId) || pairedInvolvesNew
            }
            reconciledUserSegments.append(contentsOf: osSegmentsInvolvingNewDisplays)
        }

        return ReconcileResult(
            displays: displays,
            userSegments: reconciledUserSegments,
            inactiveUserSegments: inactiveUserSegments
        )
    }
}
