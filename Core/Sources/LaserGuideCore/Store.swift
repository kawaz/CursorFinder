// Store (DR-0004: 純関数 reduce + Action ログ/replay)
//
// reduce は参照型・グローバル状態・Date() 等の非決定性を一切使わない純関数。
// 同じ (state, action) には常に同じ (state, [Effect]) を返す。ログへの記録・実際の副作用実行は
// 呼び出し側 (後続の runtime 層) の責務であり、ここでは型 (ActionLog) と replay 関数のみ用意する。
import Foundation

public enum Store {

    /// 唯一の reduce エントリポイント。
    public static func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        switch action {
        case let .mouseMoved(location, deltaSign):
            return reduceMouseMoved(state, location: location, deltaSign: deltaSign)
        case let .displayConfigurationChanged(snapshots):
            return reduceDisplayConfigurationChanged(state, snapshots: snapshots)
        case let .eventTapDisabled(reason):
            return reduceEventTapDisabled(state, reason: reason)
        case let .calibration(calibrationAction):
            return reduceCalibration(state, calibrationAction)
        case let .settingsChanged(configuration):
            return reduceSettingsChanged(state, configuration: configuration)
        }
    }

    /// action 列を初期状態に順次適用した最終状態を返す (デバッグ再生用)。
    public static func replay(initial: AppState, actions: [Action]) -> AppState {
        actions.reduce(initial) { state, action in reduce(state, action).0 }
    }

    // ================================
    // mouseMoved (DR-0004 fast/slow path)
    // ================================

    private static func reduceMouseMoved(
        _ state: AppState, location: LogicalPoint, deltaSign: DeltaSign
    ) -> (AppState, [Effect]) {
        // 権限失効時はワープ判定を止める (レーザー描画は NSEvent monitor 経由の別系統で継続する
        // ため、ここでの履歴更新は次回判定のための維持に過ぎない)。
        guard !state.tapHealth.isWarpDisabledByPermissionLoss else {
            let currentDisplayId = state.tables.displayId(containing: location)
            return (shiftHistory(state, to: location, displayId: currentDisplayId), [])
        }

        let prevEntry = state.currentMouse
        let currentDisplayId = state.tables.displayId(containing: location)
        let moveClass = Trigger.classify(
            prev: (point: prevEntry?.point ?? location, displayId: prevEntry?.displayId),
            current: (point: location, displayId: currentDisplayId),
            deltaSign: (dx: deltaSign.dx, dy: deltaSign.dy),
            tables: state.tables,
            edgeEpsilon: state.configuration.edgeEpsilon
        )

        switch moveClass {
        case .interior:
            return (shiftHistory(state, to: location, displayId: currentDisplayId), [])

        case let .px(crossing, previousDisplayId, currentDisplayIdFromClass):
            let judgement = Judgement.judgeCrossing(
                line: crossing, sourceDisplayId: previousDisplayId, tables: state.tables)
            switch judgement {
            case .pp, .noCrossing:
                return (shiftHistory(state, to: location, displayId: currentDisplayIdFromClass), [])
            case let .pb(clampTo):
                // DR-0004: ワープ後の履歴リセット。差し戻し先 = source display (previousDisplayId)
                // の座標で 2 世代とも埋め直す。これを怠ると次イベントで PX が誤発火する。
                let updated = shiftHistory(state, to: clampTo, displayId: previousDisplayId)
                return (updated, [.rewriteEventLocation(clampTo)])
            }

        case let .bx(displayId, sides):
            let outcome = Judgement.judgeBlockedWithFallback(
                at: location, displayId: displayId, sides: sides, tables: state.tables,
                inwardInsetMillimeters: state.configuration.warpInwardInsetMillimeters)
            switch outcome {
            case .block, .blockDanglingReference:
                return (shiftHistory(state, to: location, displayId: displayId), [])
            case let .pass(warpTo):
                // DR-0004: ワープ後の履歴リセット。着地先モニタを warpTo の包含判定で確定し、
                // 2 世代とも埋め直す (直後の mouseMoved が旧モニタとの PX として誤発火しない)。
                let targetDisplayId = state.tables.displayId(containing: warpTo)
                let updated = shiftHistory(state, to: warpTo, displayId: targetDisplayId)
                return (updated, [.rewriteEventLocation(warpTo)])
            }
        }
    }

    private static func shiftHistory(_ state: AppState, to point: LogicalPoint, displayId: String?) -> AppState {
        var next = state
        next.previousMouse = state.currentMouse
        next.currentMouse = MouseHistoryEntry(point: point, displayId: displayId)
        return next
    }

    // ================================
    // displayConfigurationChanged
    // ================================

    private static func reduceDisplayConfigurationChanged(
        _ state: AppState, snapshots: [DisplaySnapshot]
    ) -> (AppState, [Effect]) {
        // 既知の id には従来の pose を引き継ぐ (キャリブレーション情報は OS から来ないため)。
        // 新規検出モニタは未校正状態として恒等 pose を仮置きする (Phase 2 でのフォールバック
        // DPI 推定に置き換わる想定、DR-0005)。
        let existingIds = Set(state.displays.map(\.id))
        let newDisplays = snapshots.map { snapshot -> Display in
            if let existing = state.displays.first(where: { $0.id == snapshot.id }) {
                return Display(id: snapshot.id, logicalBounds: snapshot.logicalBounds, pose: existing.pose)
            }
            return Display(id: snapshot.id, logicalBounds: snapshot.logicalBounds, pose: .identity)
        }

        // DR-0006 決定 5: 「永続設定が無い新規構成の検出時」も osPassSegments のコピーで
        // userSegments を初期化する対象に含める。ここでは「今回新たに現れたモニタ (id が
        // 既存 displays に無かった) が絡む隣接ペア」を追加対象にする。既存モニタ同士の隣接は、
        // ユーザが既に見た構成 (PB へ明示的に倒した可能性を含む) なので自動追加で上書きしない
        // (= 決定 5 の「PB はユーザが明示的にセグメントを削除した時にのみ生じる」という不変条件
        // を、構成変更のたびに壊さないため)。
        //
        // 隣接ペアは必ず 2 個のセグメント (a→b, b→a) が組で生成される。片方だけを条件判定すると、
        // 「新規モニタ側の 1 セグメントだけ追加され、既存モニタ側の対セグメントが漏れる」非対称な
        // 状態になり、A→B は PP なのに B→A は PB という向きで挙動が割れてしまう。ペアのどちらか
        // 一方でも新規モニタが絡んでいれば両方を追加する。
        let newlyAppearedIds = Set(newDisplays.map(\.id)).subtracting(existingIds)
        var nextUserSegments = state.userSegments
        if !newlyAppearedIds.isEmpty {
            let allOSSegments = Adjacency.detectOSPassSegments(newDisplays)
            let osSegmentsById = Dictionary(uniqueKeysWithValues: allOSSegments.map { ($0.id, $0) })
            let existingUserSegmentIds = Set(nextUserSegments.map(\.id))
            let osSegmentsInvolvingNewDisplays = allOSSegments.filter { seg in
                guard !existingUserSegmentIds.contains(seg.id) else { return false }
                let pairedInvolvesNew = osSegmentsById[seg.pairedSegmentId].map { newlyAppearedIds.contains($0.displayId) } ?? false
                return newlyAppearedIds.contains(seg.displayId) || pairedInvolvesNew
            }
            nextUserSegments.append(contentsOf: osSegmentsInvolvingNewDisplays)
        }

        var next = state
        next.userSegments = nextUserSegments
        next.replaceDisplaysAndRebuildTables(newDisplays)
        return (next, [])
    }

    // ================================
    // eventTapDisabled
    // ================================

    private static func reduceEventTapDisabled(
        _ state: AppState, reason: TapDisableReason
    ) -> (AppState, [Effect]) {
        switch reason {
        case .timeout, .userInput:
            // 一過性のブリップ。state には残さず再有効化のみ effect で依頼する。
            return (state, [.reenableTap])
        case .permissionRevoked:
            var next = state
            next.tapHealth.isWarpDisabledByPermissionLoss = true
            return (next, [.notifyPermissionLost])
        }
    }

    // ================================
    // calibration
    // ================================

    private static func reduceCalibration(
        _ state: AppState, _ action: CalibrationAction
    ) -> (AppState, [Effect]) {
        var next = state
        switch action {
        case let .dragStart(displayId):
            next.calibration.draggingDisplayId = displayId
            if next.calibration.candidatePoses[displayId] == nil,
               let current = state.displays.first(where: { $0.id == displayId }) {
                next.calibration.candidatePoses[displayId] = current.pose
            }
            return (next, [])

        case let .dragMove(displayId, candidatePose):
            // ドラッグ中でないモニタへの dragMove は無視する (状態機械の不整合を防ぐ)。
            guard state.calibration.draggingDisplayId == displayId else { return (state, []) }
            next.calibration.candidatePoses[displayId] = candidatePose
            return (next, [])

        case .dragEnd:
            next.calibration.draggingDisplayId = nil
            return (next, [])

        case .preview:
            let previewDisplays = state.calibration.previewDisplays(basedOn: state.displays)
            next.calibration.previewTables = WarpTables(displays: previewDisplays, userSegments: state.userSegments)
            return (next, [])

        case .commit:
            let committedDisplays = state.calibration.previewDisplays(basedOn: state.displays)
            next.replaceDisplaysAndRebuildTables(committedDisplays)
            next.calibration = .idle
            // 確定後の displays (= 候補 pose 昇格済み) から V3 payload を組む。userSegments は
            // hardwareId (displayId) でグルーピングして各 PersistedDisplayV3 に振り分ける。
            return (next, [.persist(buildPersistedWorkspaceV3(displays: committedDisplays, userSegments: state.userSegments))])

        case .cancel:
            next.calibration = .idle
            return (next, [])
        }
    }

    // ================================
    // settingsChanged
    // ================================

    private static func reduceSettingsChanged(
        _ state: AppState, configuration: AppConfiguration
    ) -> (AppState, [Effect]) {
        var next = state
        next.configuration = configuration
        // 現 V3 スキーマは configuration を含まないため、write のトリガとしてのみ persist を発行
        // (displays + userSegments のスナップショット、pose は再取得しても同値だが冪等性は保たれる)。
        // configuration 自体の永続化は Persistence/ 所有者がスキーマ拡張したときに追記予定。
        return (next, [.persist(buildPersistedWorkspaceV3(displays: state.displays, userSegments: state.userSegments))])
    }

    // ================================
    // Persistence payload build
    // ================================

    /// displays + userSegments から PersistedWorkspaceV3 を組む。userSegments は displayId で
    /// 振り分ける (対向側は相手モニタの PersistedDisplayV3 に自然に入る)。displays に無い
    /// displayId を持つ孤立 userSegments は捨てる (再構成時に持ち主モニタが取れないため、
    /// reconcile 側でも扱いようがない)。
    static func buildPersistedWorkspaceV3(
        displays: [Display], userSegments: [PassSegment]
    ) -> PersistedWorkspaceV3 {
        let byDisplay = Dictionary(grouping: userSegments, by: { $0.displayId })
        let persisted = displays.map { d in
            PersistedDisplayV3(
                hardwareId: d.id,
                pose: d.pose,
                userSegments: byDisplay[d.id] ?? []
            )
        }
        return PersistedWorkspaceV3(displays: persisted)
    }
}

/// リングバッファの Action ログ (デバッグ再生用)。記録自体は runtime 層の責務、ここでは
/// 容量固定の器だけを提供する。
public struct ActionLogEntry: Equatable, Sendable {
    public let sequence: Int
    public let action: Action
    public init(sequence: Int, action: Action) {
        self.sequence = sequence
        self.action = action
    }
}

public struct ActionLog: Sendable {
    public let capacity: Int
    public private(set) var entries: [ActionLogEntry] = []
    private var nextSequence: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "ActionLog: capacity は 1 以上")
        self.capacity = capacity
    }

    public mutating func append(_ action: Action) {
        entries.append(ActionLogEntry(sequence: nextSequence, action: action))
        nextSequence += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 記録済み action だけを使って任意の initial state から状態を再構成する。
    public func replay(from initial: AppState) -> AppState {
        Store.replay(initial: initial, actions: entries.map(\.action))
    }
}
