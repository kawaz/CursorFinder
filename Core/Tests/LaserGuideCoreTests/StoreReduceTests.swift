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

    /// ユーザセグメントが越境位置 (y=500) をカバーしない (PB) 場合、クランプ effect が出て、
    /// 履歴は「差し戻し先 = source display (A)」の id で埋め直される。
    ///
    /// clampTo の具体座標値は幾何コアのレビュー (C-1/C-2、半開区間規約下での隣接モニタ所属問題の
    /// 修正) で「境界値ちょうど → 内向き inset 付き」に変わる予定 (2026-07-10 team-lead 予告)。
    /// そのため座標は厳密一致させず、effect の種類・件数・所属モニタのみを固定する。
    func testPBCrossingProducesClampEffectAndHistoryStaysOnSourceDisplay() {
        let setup = twoAdjacentDisplaysWithPartialOverlapUserSegments()
        var state = AppState(displays: setup.displays, userSegments: setup.userSegments)

        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))

        let (next, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        guard case let .rewriteEventLocation(clampTo)? = effects.first, effects.count == 1 else {
            return XCTFail("PB は rewriteEventLocation effect を 1 件出すはず: \(effects)")
        }
        XCTAssertEqual(next.currentMouse?.point, clampTo, "履歴の座標は effect が指すクランプ先と同期している")
        XCTAssertEqual(next.currentMouse?.displayId, "A", "PB の差し戻し先は source display (A) のまま")
        XCTAssertEqual(next.previousMouse?.displayId, "A")
    }

    // ==================
    // (d) BP でワープ effect + 履歴リセットにより直後の mouseMoved が PX 誤発火しない
    // ==================

    /// OS 隣接のない A/C を仮想接続するユーザセグメントで BX→BP ワープが発生すると、
    /// 履歴が着地先 (C) にリセットされる。直後の C 内での小移動は「前回も C」なので
    /// interior になり、誤って PX (旧モニタ A との差分) と判定されないことを固定する。
    ///
    /// warpTo の具体座標値は幾何コアのレビュー (C-1/C-2、rate 写像の意味論変更・inset 付き
    /// clampTo への変更) で変わる予定 (2026-07-10 team-lead 予告)。座標は厳密一致させず、
    /// 「rewriteEventLocation が 1 件出る」「着地先が C である」ことのみ固定する。フォローアップの
    /// 移動先も実際の着地点 (dst) からの相対オフセットにして、座標変更に追従できるようにする。
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
        XCTAssertEqual(afterWarp.currentMouse?.point, dst, "履歴の座標は effect が指す着地点と同期している")
        XCTAssertEqual(afterWarp.currentMouse?.displayId, "C", "履歴がワープ後のモニタ C にリセットされている")
        state = afterWarp

        // 直後の C 内での小移動 (着地点からの相対オフセット): 前回も今回も C なので interior。
        // 旧 A との PX 誤発火が起きない核心テスト。
        let (afterFollowUp, followUpEffects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: dst.x + 0.1, y: dst.y), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(followUpEffects, [], "履歴リセットが効いていれば PX は発生しない")
        XCTAssertEqual(afterFollowUp.currentMouse?.displayId, "C")
    }

    // ==================
    // (d-2) カドで優先辺が block でも次候補辺で BP ワープが成立する (M-2, Store 経由の統合確認)
    // ==================

    /// A の右下カドへ斜めに押し付ける。bottom 辺は OS 隣接も userSegment もない (BB)、
    /// right 辺は OS 隣接がなく userSegment で C へ橋渡し (BP)。優先度は bottom が先だが、
    /// Trigger.classify が両候補を返し、Store 経由で Judgement.judgeBlockedWithFallback が
    /// bottom (block) → right (pass) と 2 段評価してワープが成立することを固定する。
    func testCornerFallbackWarpsViaSecondCandidateWhenPrimarySideBlocked() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        let c = Display(id: "C", logicalBounds: LogicalRect(minX: 5000, minY: 0, maxX: 6920, maxY: 1080), pose: .identity)
        let userSegments = [
            PassSegment(id: "u-A", displayId: "A", side: .right, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-C"),
            PassSegment(id: "u-C", displayId: "C", side: .left, logicalStart: 0, logicalEnd: 1080, pairedSegmentId: "u-A"),
        ]
        var state = AppState(displays: [a, c], userSegments: userSegments)

        // A のカド付近にいる
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 1060), deltaSign: DeltaSign(dx: 1, dy: 1)))
        XCTAssertEqual(state.currentMouse?.displayId, "A")

        // カド近傍 (実機 max クランプ位置、A 内に留まる ε 近傍) へ、右下方向の delta で押し付け。
        // ちょうど (1920,1080) だと半開区間規約でどの display にも所属しなくなり PX 経路に化けて
        // しまうため、A 内側に留まる値を使う (testBXOnMaxSideEdgeWithOSClampOffset と同じ考え方)。
        let (afterMove, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1919.98, y: 1079.98), deltaSign: DeltaSign(dx: 1, dy: 1)))
        guard case .rewriteEventLocation? = effects.first, effects.count == 1 else {
            return XCTFail("bottom が block でも right 候補で BP ワープが成立するはず: \(effects)")
        }
        XCTAssertEqual(afterMove.currentMouse?.displayId, "C", "フォールバックで採用された right 候補の着地先は C")
    }

    // ==================
    // (e) 構成変更で tables 再構築、直後の判定が新構成で動く
    // ==================

    /// 再配置前: A と C は OS 非隣接 (BX→BB、userSegments 空なので block)。
    /// displayConfigurationChanged で C を A に隣接させると、直後の同種の越境操作が
    /// 「OS が通す PX」に変わり、userSegments が空なので PB (クランプ差し戻し) の effect が出る。
    /// 派生 tables が displayConfigurationChanged の reduce だけで再構築され、次の mouseMoved が
    /// 即座にその新構成で判定することを固定する。
    ///
    /// clampTo の具体座標値は幾何コアのレビュー (C-1/C-2) で変わる予定 (2026-07-10 team-lead 予告)。
    /// 座標は厳密一致させず、判定が PX→PB に切り替わったこと (effect の種類・件数) と
    /// 差し戻し先の所属モニタのみを固定する。
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
        guard case .rewriteEventLocation? = moveEffects.first, moveEffects.count == 1 else {
            return XCTFail("新構成の隣接に基づき PX→PB (rewriteEventLocation 1 件) と判定されるはず: \(moveEffects)")
        }
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
        // DR-0007 決定 2/6/7 + 2026-07-10 team-lead 追加指示: persist payload は
        // PersistedWorkspaceV3 で確定 pose を含む (旧 PersistedWorkspace は pose を運ばない実装漏れ)。
        // 意図: 「commit で書かれる payload は、確定後の pose (= candidate 昇格済み) と
        // 現 userSegments を hardwareId 単位に振り分けたもの」。緩めずに payload そのものを固定する。
        XCTAssertEqual(effects.count, 1, "commit は persist を 1 件だけ発行")
        guard case let .persist(payload)? = effects.first else {
            return XCTFail("commit は persist effect を発行するはず: \(effects)")
        }
        XCTAssertEqual(payload.version, PersistedWorkspaceV3.currentVersion)
        XCTAssertEqual(payload.displays.count, committed.displays.count, "payload の displays は確定後の displays と同数")
        for d in committed.displays {
            guard let entry = payload.displays.first(where: { $0.hardwareId == d.id }) else {
                return XCTFail("hardwareId=\(d.id) が payload に無い")
            }
            XCTAssertEqual(entry.pose, d.pose, "commit で昇格した確定 pose が payload に載っている")
            XCTAssertEqual(Set(entry.userSegments), Set(setup.userSegments.filter { $0.displayId == d.id }),
                           "userSegments は displayId でグルーピング済み")
        }
        XCTAssertNotEqual(committed.tables, confirmedTablesBefore, "commit で初めて確定済み tables が候補 pose を反映する")
        XCTAssertEqual(committed.calibration, .idle, "commit 後はキャリブレーション編集状態がクリアされる")
    }

    /// キャリブレーション commit で **候補 pose (= 単なる旧値ではない)** が payload の pose に
    /// 昇格していることを直接固定する (旧 PersistedWorkspace 型では pose を運べず、この不変条件を
    /// 表現できなかった。追加された PersistedWorkspaceV3 で表現可能になったので固定する)。
    func testCommitPersistsUpgradedCandidatePoseNotOriginal() {
        let displays = [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
        var state = AppState(displays: displays, userSegments: [])
        (state, _) = Store.reduce(state, .calibration(.dragStart(displayId: "A")))
        let candidate = DisplayPose(translate: PhysicalPoint(x: 42, y: -7), scaleX: 1, scaleY: 1)
        (state, _) = Store.reduce(state, .calibration(.dragMove(displayId: "A", candidatePose: candidate)))
        let (_, effects) = Store.reduce(state, .calibration(.commit))
        guard case let .persist(payload)? = effects.first else {
            return XCTFail("commit は persist effect を発行するはず: \(effects)")
        }
        let entryA = payload.displays.first(where: { $0.hardwareId == "A" })
        XCTAssertEqual(entryA?.pose, candidate, "commit の payload は候補 pose を確定として保持する")
        let entryB = payload.displays.first(where: { $0.hardwareId == "B" })
        XCTAssertEqual(entryB?.pose, .identity, "ドラッグしていない B の pose は identity のまま")
    }

    /// settingsChanged 経由の persist も同じ payload 構造で発行される (configuration は現 V3
    /// スキーマに含まれないので payload には現れない — Persistence/ 所有者が拡張したら追記予定)。
    /// 「settingsChanged が persist を発行する」不変条件と、payload が現 displays + userSegments を
    /// 反映することを固定する。
    func testSettingsChangedEmitsPersistWithCurrentDisplaysAndUserSegments() {
        let setup = twoAdjacentDisplaysWithFullOverlapUserSegments()
        let state = AppState(displays: setup.displays, userSegments: setup.userSegments)
        let (_, effects) = Store.reduce(state, .settingsChanged(AppConfiguration(edgeEpsilon: 0.5, warpInwardInsetMillimeters: 0.003)))
        guard case let .persist(payload)? = effects.first, effects.count == 1 else {
            return XCTFail("settingsChanged は persist を 1 件発行するはず: \(effects)")
        }
        XCTAssertEqual(payload.version, PersistedWorkspaceV3.currentVersion)
        XCTAssertEqual(Set(payload.displays.map(\.hardwareId)), Set(setup.displays.map(\.id)))
        // hardwareId でグルーピングされた userSegments の合計は元の userSegments と同集合
        let flattened = Set(payload.displays.flatMap(\.userSegments))
        XCTAssertEqual(flattened, Set(setup.userSegments))
    }

    // ==================
    // DR-0006 決定 5: 初期状態は osPassSegments のコピー
    // (2026-07-10 実機フィードバック #4 の確定原因: AppState(displays:, userSegments: []) が
    //  全継ぎ目を PB 化させ、OS のネイティブ通過を能動的にブロックしていた)
    // ==================

    /// AppState.initial(displays:) は userSegments を空にせず osPassSegments のコピーで
    /// 初期化する。よって起動直後にモニタ間の継ぎ目を横切っても PP (OS の通過通り) になり、
    /// rewriteEventLocation (PB のクランプ差し戻し) effect は出ない。
    func testInitialAppStateDefaultsUserSegmentsToOSCopySoFreshBoundaryCrossingIsPP() {
        let displays = [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
        var state = AppState.initial(displays: displays)
        XCTAssertFalse(state.userSegments.isEmpty, "初期状態の userSegments は空であってはいけない (空だと全継ぎ目が PB 化する)")

        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1900, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        let (next, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1940, y: 500), deltaSign: DeltaSign(dx: 1, dy: 0)))
        XCTAssertEqual(effects, [], "初期状態のままの継ぎ目越境は PP (OS 通過通り)、rewriteEventLocation は出ない")
        XCTAssertEqual(next.currentMouse?.displayId, "B", "PP なので OS の通過通り B へ移った履歴になる")
    }

    /// 実機トポロジ (findings/2026-07-09-macos-display-api-verification.md §4): 内蔵 Retina
    /// bounds 0..2056 × 0..1329 (下) と LG ULTRAGEAR+ bounds -258..3182 × -1440..0 (上) が
    /// y=0 の継ぎ目で上下に隣接する構成。継ぎ目共通区間 [0,2056] の中央 (x=1000) を縦断しても、
    /// 初期状態のままなら OS のネイティブ通過がブロックされず素通しになることを固定する
    /// (#4 の実機症状「継ぎ目の真ん中で詰まるが角沿いは通れる」の再現条件そのもの)。
    func testInitialAppStateAllowsPassThroughAtSeamCenterOnRealTopology() {
        let builtIn = Display(id: "built-in", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329), pose: .identity)
        let lg = Display(id: "LG", logicalBounds: LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0), pose: .identity)
        var state = AppState.initial(displays: [builtIn, lg])

        // built-in 内部 (継ぎ目のすぐ下、x=1000 は共通区間 [0,2056] の中央付近)
        (state, _) = Store.reduce(state, .mouseMoved(location: LogicalPoint(x: 1000, y: 1), deltaSign: DeltaSign(dx: 0, dy: -1)))
        XCTAssertEqual(state.currentMouse?.displayId, "built-in")

        // 継ぎ目 (y=0) を上向き (LG 方向) に横断
        let (next, effects) = Store.reduce(
            state, .mouseMoved(location: LogicalPoint(x: 1000, y: -1), deltaSign: DeltaSign(dx: 0, dy: -1)))
        XCTAssertEqual(effects, [], "継ぎ目中央の縦断は初期状態のままなら PP、詰まらず素通しになる")
        XCTAssertEqual(next.currentMouse?.displayId, "LG", "越境後の履歴は LG に移っている")
    }

    /// displayConfigurationChanged で「まったく新規」のモニタが検出された場合も、決定 5 の
    /// 対象 (= 永続設定が無い新規構成の検出時) として osPassSegments のコピーが userSegments に
    /// 追加され、直後の越境が PP になる。一方、既存モニタ同士の隣接には手を出さず、ユーザが
    /// 既に編集した (PB へ倒した) 可能性のある userSegments を構成変更のたびに上書きしない
    /// ことも併せて固定する。
    func testDisplayConfigurationChangedAddsOSCopyOnlyForNewlyAppearedDisplays() {
        let a = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        // 初期状態: A 単体、userSegments は当然空 (隣接なし)
        var state = AppState.initial(displays: [a])
        XCTAssertEqual(state.userSegments, [], "隣接モニタがなければ osPassSegments は空")

        // 既存 A に、A の右辺へ既にユーザが明示的に PB 化した想定の隣接構成へ更新する準備として、
        // まず B を新規追加 (新規検出 → os コピーが自動追加される想定)。
        let (afterAddB, _) = Store.reduce(state, .displayConfigurationChanged([
            DisplaySnapshot(id: "A", logicalBounds: a.logicalBounds),
            DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
        ]))
        XCTAssertTrue(
            afterAddB.userSegments.contains { $0.displayId == "A" && $0.side == .right },
            "新規検出された B との隣接は os コピーとして userSegments に自動追加される")
        state = afterAddB

        // ユーザが A-B 間を明示的に PB 化 (userSegments から A.right 側を削除) した状態を模擬。
        state.userSegments.removeAll { $0.displayId == "A" && $0.side == .right || $0.displayId == "B" && $0.side == .left }
        XCTAssertFalse(state.userSegments.contains { $0.displayId == "A" && $0.side == .right })

        // 同じ構成のまま displayConfigurationChanged が再度発火しても (A/B とも既存 id なので)
        // 削除した PB 化が自動で復活しない (= ユーザの明示編集を上書きしない)。
        let (afterNoOpReconfig, _) = Store.reduce(state, .displayConfigurationChanged([
            DisplaySnapshot(id: "A", logicalBounds: a.logicalBounds),
            DisplaySnapshot(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080)),
        ]))
        XCTAssertFalse(
            afterNoOpReconfig.userSegments.contains { $0.displayId == "A" && $0.side == .right },
            "既存モニタ同士の再構成では、ユーザが明示削除した userSegments を自動で復活させない")
    }

    // ================================
    // focusedWindowChanged (DR-0011)
    // ================================
    //
    // 検証したいこと (DR-0009 決定 2 「連続切替時は世代カウンタで上書き」+ DR-0011 決定 4 の
    // windowFrame 追加、の輪郭):
    //   (a) 初回発火で focusFlash が生成される (nil → セット、generation=1、windowFrame も保存)
    //   (b) 同じ displayId への連続発火でも generation が単調増加する (= 同一モニタ内のアプリ
    //       切替でも視覚エフェクトを再発火できる、DR-0009 決定 5 の Phase A 要件と対応)
    //   (c) 別 displayId への切替で displayId が差し替わり generation も進む
    //   (d) effect は発生しない (フォーカスフラッシュは描画層のみの状態遷移、Store は純関数を保つ)
    //   (e) 同一 displayId・同一 generation の流れの中でも、発火のたびに windowFrame が最新値へ
    //       上書きされる (震源はウィンドウが動けば追従する必要があるため、DR-0011 決定 4)

    private static let sampleWindowFrameA = LogicalRect(minX: 100, minY: 100, maxX: 500, maxY: 400)
    private static let sampleWindowFrameB = LogicalRect(minX: 2000, minY: 50, maxX: 2400, maxY: 350)

    /// (a) 初回発火: focusFlash が nil の状態から `.focusedWindowChanged(A, frame)` を投入すると、
    ///     `FocusFlashState(displayId: "A", windowFrame: frame, generation: 1)` にセットされる
    ///     (generation は 1 開始)。effect は発生しない。
    func testFocusedWindowChangedInitialFiringSetsGenerationOne() {
        var state = AppState.initial(displays: [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
        ])
        XCTAssertNil(state.focusFlash, "初期状態は未発火")

        let (next, effects) = Store.reduce(state, .focusedWindowChanged(displayId: "A", windowFrame: Self.sampleWindowFrameA))
        XCTAssertEqual(effects, [], "focusedWindowChanged は描画専用の状態遷移で effect を出さない")
        XCTAssertEqual(next.focusFlash, FocusFlashState(displayId: "A", windowFrame: Self.sampleWindowFrameA, generation: 1))
        state = next
    }

    /// (b) 同一 displayId への連続発火で generation が単調増加する。
    ///     同一モニタ内でアプリを切り替えた場合も「軽く再発火」できる仕様 (DR-0009 決定 5) の固定。
    ///     windowFrame は毎回同じ値を渡しても generation は増え続ける (発火自体が再発火トリガー)。
    func testFocusedWindowChangedSameDisplayIncrementsGeneration() {
        var state = AppState.initial(displays: [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
        ])
        for expected in UInt64(1)...UInt64(4) {
            let (next, effects) = Store.reduce(state, .focusedWindowChanged(displayId: "A", windowFrame: Self.sampleWindowFrameA))
            XCTAssertEqual(effects, [])
            XCTAssertEqual(next.focusFlash, FocusFlashState(displayId: "A", windowFrame: Self.sampleWindowFrameA, generation: expected))
            state = next
        }
    }

    /// (c) 別 displayId への切替で displayId が差し替わり、かつ generation は前回から進む
    ///     (直前が A の generation=2 なら、B への切替は generation=3)。連続切替の識別性を担保する。
    ///     windowFrame も displayId と一緒に切替先の値へ差し替わる。
    func testFocusedWindowChangedCrossDisplaySwitchIncrementsGenerationAndSwapsId() {
        var state = AppState.initial(displays: [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ])
        // A → A → B → A の順で切り替え。generation は 1, 2, 3, 4 と単調増加。
        let sequence: [(id: String, frame: LogicalRect, gen: UInt64)] = [
            ("A", Self.sampleWindowFrameA, 1),
            ("A", Self.sampleWindowFrameA, 2),
            ("B", Self.sampleWindowFrameB, 3),
            ("A", Self.sampleWindowFrameA, 4),
        ]
        for entry in sequence {
            let (next, effects) = Store.reduce(state, .focusedWindowChanged(displayId: entry.id, windowFrame: entry.frame))
            XCTAssertEqual(effects, [])
            XCTAssertEqual(next.focusFlash, FocusFlashState(displayId: entry.id, windowFrame: entry.frame, generation: entry.gen))
            state = next
        }
    }

    /// (e) 同一 displayId のまま windowFrame だけが変わる発火 (= ウィンドウをドラッグして
    ///     同じモニタ内で移動させた直後に再フォーカスした想定) でも、generation は増加し
    ///     windowFrame は最新値へ上書きされる (震源が古い位置に固定されたままにならないことの固定)。
    func testFocusedWindowChangedUpdatesWindowFrameOnSameDisplayRefire() {
        let state = AppState.initial(displays: [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
        ])
        let (afterFirst, _) = Store.reduce(state, .focusedWindowChanged(displayId: "A", windowFrame: Self.sampleWindowFrameA))
        XCTAssertEqual(afterFirst.focusFlash?.windowFrame, Self.sampleWindowFrameA)

        let movedFrame = LogicalRect(minX: 300, minY: 300, maxX: 700, maxY: 600)
        let (afterMove, effects) = Store.reduce(afterFirst, .focusedWindowChanged(displayId: "A", windowFrame: movedFrame))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(afterMove.focusFlash, FocusFlashState(displayId: "A", windowFrame: movedFrame, generation: 2),
                        "displayId が同じでも windowFrame は最新の発火位置へ更新される")
    }
}
