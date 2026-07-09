// Store.reduce の「action 列 → state 列 + effect 列」テスト (DR-0004 単方向データフロー)
//
// 各テストは「何を保証するか」をコメントで明示する。座標・エッジクランプ値は
// docs/findings/2026-07-09-macos-display-api-verification.md §4 の実機観測 (max 側 -0.02px
// インセット) に合わせ、Trigger/Judgement 側の既存テスト (TriggerClassificationTests /
// JudgementDecisionTableTests) と同じ構成を踏襲する。
import XCTest
@testable import LaserGuideCore

final class StoreReduceTests: XCTestCase {

    // ==================
    // 共通ヘルパー
    // ==================

    private func twoAdjacentDisplaysWithFullOverlapUserSegments() -> (displays: [Display], userSegments: [PassSegment]) {
        let displays = [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
        let userSegments = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        return (displays, userSegments)
    }

    private func twoAdjacentDisplaysWithPartialOverlapUserSegments() -> (displays: [Display], userSegments: [PassSegment]) {
        let displays = [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
        // y=500 の越境位置をカバーしない上端のみのユーザセグメント (PB を発生させる)
        let userSegments = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-B"),
            PassSegment(id: "u-B", displayId: "B", side: .left, logicalStart: 0, logicalEnd: 300, pairedSegmentId: "u-A"),
        ]
        return (displays, userSegments)
    }

    private func farApartDisplaysWithBridgingUserSegments() -> (displays: [Display], userSegments: [PassSegment]) {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        let userSegments = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        return ([a, c], userSegments)
    }

    // ==================
    // (a) interior 連発で effect が出ない
    // ==================

    /// 同一モニタ内を連続移動する限り、何回 reduce しても effect は空で、履歴だけが素直にシフトする。
    func testInteriorRepeatedMovesProduceNoEffects() {
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        let points = [
            LogicalPoint(x: 100, y: 100),
            LogicalPoint(x: 150, y: 100),
            LogicalPoint(x: 200, y: 150),
        ]
        for p in points {
            let (next, effects) = Store.reduce(state, .mouseMoved(location: p, deltaSign: DeltaSign(dx: 1, dy: 1)))
            XCTAssertEqual(effects, [], "interior 移動で effect が発生してはいけない: \(p)")
            state = next
        }
        XCTAssertEqual(state.currentMouse, MouseHistoryEntry(point: points.last!, displayId: "A"))
        XCTAssertEqual(state.previousMouse?.point, points[points.count - 2])
    }

    // ==================
    // (b) PP 越境で effect なし + 履歴が新モニタに
    // ==================

    /// os セグメントと同じ範囲を丸ごとカバーするユーザセグメント (PP) を A→B に横切ると、
    /// OS の通過をそのまま許すので effect は出ず、履歴の所属モニタが B に切り替わる。
    func testPPCrossingProducesNoEffectAndHistoryMovesToNewDisplay() {
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        // A 側に居ることを履歴に持たせる
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(state.currentMouse?.displayId, "A")

        // B へ越境
        let (next, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(effects, [], "PP は OS の通過に任せるので effect なし")
        XCTAssertEqual(next.currentMouse, MouseHistoryEntry(point: LogicalPoint(x: 1940, y: 500), displayId: "B"))
    }

    // ==================
    // (c) PB で差し戻し effect + 履歴が差し戻し先
    // ==================

    /// ユーザセグメントが越境位置 (y=500) をカバーしない (PB) 場合、交点へのクランプ effect が出て、
    /// 履歴は「差し戻し先 = source display (A)」の座標・id で埋め直される。
    func testPBCrossingProducesClampEffectAndHistoryStaysOnSourceDisplay() {
        let setup = twoAdjacentDisplaysWithPartialOverlapUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))

        let (next, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(effects, [.rewriteEventLocation(LogicalPoint(x: 1920, y: 500))])
        XCTAssertEqual(next.currentMouse, MouseHistoryEntry(point: LogicalPoint(x: 1920, y: 500), displayId: "A"),
                       "PB の差し戻し先は source display (A) のまま")
        XCTAssertEqual(next.previousMouse?.displayId, "A")
    }

    // ==================
    // (d) BP でワープ effect + 履歴リセットにより直後の mouseMoved が PX 誤発火しない
    // ==================

    /// OS 隣接のない A/C を仮想接続するユーザセグメントで BX→BP ワープが発生すると、
    /// 履歴が着地先 (C) にリセットされる。直後の C 内での小移動は「前回も C」なので
    /// interior になり、誤って PX (旧モニタ A との差分) と判定されないことを固定する。
    func testBPWarpResetsHistorySoNextMoveDoesNotFalselyTriggerPX() {
        let setup = farApartDisplaysWithBridgingUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        // A 内部にいる
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(state.currentMouse?.displayId, "A")

        // 右エッジへ押し付ける (実機観測の max 側クランプ位置 = maxX - 0.02)。
        // BX 判定は毎イベント独立に judgeBlocked を評価するため、1 回の BX で即座に BP ワープが出る
        // (「連続発火する」という DR-0004 の記述は Phase 2 の BP 速度推定器の入力になるという意味で、
        // 1 回目を無視して 2 回目で確定する、という段階を要求するものではない)。
        let (afterWarp, warpEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1919.98, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        guard case let .rewriteEventLocation(dst)? = warpEffects.first, warpEffects.count == 1 else {
            return XCTFail("BP ワープ effect が 1 件出るはず: \(warpEffects)")
        }
        XCTAssertEqual(dst.x, 5000.001, accuracy: 1e-9, "inset 込みの paired (C.left) 着地点")
        XCTAssertEqual(dst.y, 500, accuracy: 1e-9)
        XCTAssertEqual(afterWarp.currentMouse?.displayId, "C", "履歴がワープ後のモニタ C にリセットされている")
        state = afterWarp

        // 直後の C 内での小移動: 前回も今回も C なので interior。旧 A との PX 誤発火が起きない核心テスト。
        let (afterFollowUp, followUpEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 5000.1, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(followUpEffects, [], "履歴リセットが効いていれば PX は発生しない")
        XCTAssertEqual(afterFollowUp.currentMouse?.displayId, "C")
    }

    // ==================
    // (e) 構成変更で tables 再構築、直後の判定が新構成で動く
    // ==================

    /// 再配置前: A と C は OS 非隣接 (BX→BB、userSegments 空なので block)。
    /// displayConfigurationChanged で C を A に隣接させると、直後の同種の越境操作が
    /// 「OS が通す PX」に変わり、userSegments が空なので PB (クランプ差し戻し) の effect が出る。
    /// 派生 tables が displayConfigurationChanged の reduce だけで再構築され、次の mouseMoved が
    /// 即座にその新構成で判定することを固定する。
    func testDisplayConfigurationChangeRebuildsTablesForNextJudgement() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let cFar = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        var state = AppState(displays: [a, cFar], userSegments: [])

        // 再配置前: A 内部 → 右エッジへ押し付け。OS 非隣接 + userSegments 空 → BX からの block。
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        let (beforeReconfig, blockEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1919.98, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(blockEffects, [], "再配置前は隣接なしの BX → block")
        XCTAssertEqual(beforeReconfig.currentMouse?.displayId, "A")
        state = beforeReconfig

        // C を A に隣接させる (同じ幅、A の右辺に接触)
        let cAdjacent = DisplaySnapshot(id: "C", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080))
        let (afterReconfig, reconfigEffects) = Store.reduce(
            state, .displayConfigurationChanged([
                DisplaySnapshot(id: "A", logicalBounds: a.logicalBounds),
                cAdjacent,
            ]))
        XCTAssertEqual(reconfigEffects, [], "構成変更自体は effect を出さない")
        state = afterReconfig

        // 直後: 同じ越境操作が今度は OS 隣接ありの PX として扱われ、userSegments が空なので PB。
        let (afterMove, moveEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(moveEffects, [.rewriteEventLocation(LogicalPoint(x: 1920, y: 500))],
                       "新構成の隣接に基づき PX→PB と判定されるはず")
        XCTAssertEqual(afterMove.currentMouse?.displayId, "A", "PB の差し戻し先は source (A)")
    }

    // ==================
    // (f) tap disabled → reenable、権限失効 → degrade
    // ==================

    /// timeout/userInput は回復可能なブリップ。state は変えず reenableTap effect だけを出す。
    func testTapDisabledByTimeoutOrUserInputRequestsReenableWithoutStateChange() {
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        let state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        for reason: TapDisableReason in [.timeout, .userInput] {
            let (next, effects) = Store.reduce(state, .eventTapDisabled(reason: reason))
            XCTAssertEqual(effects, [.reenableTap])
            XCTAssertEqual(next, state, "回復可能な無効化では state を変えない")
        }
    }

    /// 権限失効時は tapHealth を degrade させ、notifyPermissionLost effect を出す。
    /// degrade 中は後続の mouseMoved がワープ判定 (rewriteEventLocation) を一切出さないことも併せて固定する
    /// (レーザー描画は別経路 (NSEvent monitor) で継続する前提のため、ここでは判定停止のみ確認する)。
    func testTapDisabledByPermissionRevokedDegradesWarpAndSuppressesFurtherWarps() {
        let setup = farApartDisplaysWithBridgingUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        let (afterRevoke, revokeEffects) = Store.reduce(state, .eventTapDisabled(reason: .permissionRevoked))
        XCTAssertEqual(revokeEffects, [.notifyPermissionLost])
        XCTAssertTrue(afterRevoke.tapHealth.isWarpDisabledByPermissionLoss)
        state = afterRevoke

        // 本来なら BP ワープを引き起こす操作でも、degrade 中は effect が出ない。
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        let (afterMove, moveEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1919.98, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(moveEffects, [], "権限失効中はワープ判定を行わない")
        XCTAssertTrue(afterMove.tapHealth.isWarpDisabledByPermissionLoss, "degrade 状態は維持される")
    }

    // ==================
    // (g) replay の決定性
    // ==================

    /// 同じ action 列を replay すれば何度実行しても同じ最終 state になる (reduce が純関数であることの帰結)。
    /// 途中に mouseMoved (PP/PB/BX) / displayConfigurationChanged / calibration / settingsChanged /
    /// eventTapDisabled を混在させ、非決定性が紛れ込む余地 (Date() 等) がないことを広めに確認する。
    func testReplayIsDeterministic() {
        let setup = twoAdjacentDisplaysWithPartialOverlapUserSegments()
        let initial = AppState(displays: setup.displays, userSegments: setup.userSegments)

        let actions: [Action] = [
            .mouseMoved(location: LogicalPoint(x: 100, y: 100), deltaSign: DeltaSign(dx: 1, dy: 0)),
            .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)),
            .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)),  // PB
            .settingsChanged(AppConfiguration(edgeEpsilon: 0.2, warpInwardInsetMillimeters: 0.002)),
            .calibration(.dragStart(displayId: "A")),
            .calibration(.dragMove(displayId: "A", candidatePose: DisplayPose(translate: PhysicalPoint(x: 10, y: 0), scaleX: 1, scaleY: 1))),
            .calibration(.preview),
            .calibration(.cancel),
            .eventTapDisabled(reason: .timeout),
            .displayConfigurationChanged([
                DisplaySnapshot(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080)),
                DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
            ]),
        ]

        let result1 = Store.replay(initial: initial, actions: actions)
        let result2 = Store.replay(initial: initial, actions: actions)
        XCTAssertEqual(result1, result2, "同じ action 列の replay は常に同じ最終 state を返す")

        // 段階的な reduce の積み上げと replay が一致することも確認する (replay 自体の実装検証)。
        var stepwise = initial
        for action in actions {
            stepwise = Store.reduce(stepwise, action).0
        }
        XCTAssertEqual(stepwise, result1)
    }

    /// ActionLog はリングバッファとして capacity を超えた古い action を捨てる。
    /// replay(from:) は「記録されている action だけ」を再生する (捨てられた分は再現できない = 仕様通り)。
    func testActionLogRingBufferDropsOldestBeyondCapacityAndReplaysRemaining() {
        var log = ActionLog(capacity: 2)
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        let initial = AppState(displays: setup.displays, userSegments: setup.userSegments)

        log.append(.mouseMoved(location: LogicalPoint(x: 1, y: 1), deltaSign: DeltaSign(dx: 1, dy: 0)))
        log.append(.mouseMoved(location: LogicalPoint(x: 2, y: 2), deltaSign: DeltaSign(dx: 1, dy: 0)))
        log.append(.mouseMoved(location: LogicalPoint(x: 3, y: 3), deltaSign: DeltaSign(dx: 1, dy: 0)))

        XCTAssertEqual(log.entries.count, 2, "capacity=2 を超えた分は捨てられる")
        XCTAssertEqual(log.entries.map(\.action), [
            .mouseMoved(location: LogicalPoint(x: 2, y: 2), deltaSign: DeltaSign(dx: 1, dy: 0)),
            .mouseMoved(location: LogicalPoint(x: 3, y: 3), deltaSign: DeltaSign(dx: 1, dy: 0)),
        ])

        let replayed = log.replay(from: initial)
        let expected = Store.replay(initial: initial, actions: log.entries.map(\.action))
        XCTAssertEqual(replayed, expected)
    }

    // ==================
    // 補足: キャリブレーションのプレビュー分離 (commit まで確定 tables に影響しない)
    // ==================

    /// dragStart/dragMove/preview の間、確定済み state.tables は不変。preview は
    /// calibration.previewTables にのみ反映される (判定と描画の分離、DR-0004)。
    func testCalibrationPreviewDoesNotAffectConfirmedTablesUntilCommit() {
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        let state = AppState(displays: setup.displays, userSegments: setup.userSegments)
        let confirmedTablesBefore = state.tables

        var next = state
        (next, _) = Store.reduce(next, .calibration(.dragStart(displayId: "A")))
        (next, _) = Store.reduce(next, .calibration(.dragMove(
            displayId: "A", candidatePose: DisplayPose(translate: PhysicalPoint(x: 500, y: 0), scaleX: 1, scaleY: 1))))
        XCTAssertEqual(next.tables, confirmedTablesBefore, "dragMove は確定済み tables を変えない")
        XCTAssertNil(next.calibration.previewTables, "preview action を発行するまで previewTables は構築されない")

        (next, _) = Store.reduce(next, .calibration(.preview))
        XCTAssertNotNil(next.calibration.previewTables)
        XCTAssertEqual(next.tables, confirmedTablesBefore, "preview 後も確定済み tables は不変")

        let (committed, effects) = Store.reduce(next, .calibration(.commit))
        XCTAssertEqual(effects, [.persist(PersistedWorkspace(userSegments: setup.userSegments, configuration: .default))])
        XCTAssertNotEqual(committed.tables, confirmedTablesBefore, "commit で初めて確定済み tables が候補 pose を反映する")
        XCTAssertEqual(committed.calibration, .idle, "commit 後はキャリブレーション編集状態がクリアされる")
    }
}
