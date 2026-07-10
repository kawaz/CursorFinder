// AppState (DR-0004: 唯一の source of truth)
//
// - displays / userSegments: 永続化対象の生データ
// - tables: displays/userSegments から導出される WarpTables (derived state)。
//   再構築は displayConfigurationChanged / キャリブレーション確定 (calibration(.commit)) の
//   reduce でのみ行う (DR-0004 決定「派生テーブルの事前計算」)。毎イベントの mouseMoved は
//   このフィールドを読むだけで、確保・エンコード・IO を一切行わない。
// - previousMouse / currentMouse: 2 世代のマウス履歴。BX/PX 判定 (Trigger.classify) の入力。
// - calibration: キャリブレーション編集中の候補 pose。プレビュー用の派生 (previewTables) を
//   持つが、ワープ判定 (mouseMoved の reduce) は常に確定済みの `tables` を使う。型で分離することで
//   「プレビュー中も判定は確定済みテーブルで動く」という DR-0004 の要求を表現する。
// - tapHealth: 権限失効時の degrade 状態。ワープのみ停止、レーザー描画は別経路 (NSEvent monitor)
//   で継続するため、state 側はワープ判定の抑止フラグだけを持てば足りる。
import Foundation

/// mouseMoved の delta 符号のみを運ぶ型 (DR-0006 決定 3: 大きさに依存する契約は置かない)。
/// Trigger.classify の `(dx: Int, dy: Int)` タプル引数と等価だが、Action を Equatable にするため
/// 名前付き構造体にする (タプルは Equatable 合成の対象にできない)。
public struct DeltaSign: Equatable, Hashable, Sendable {
    public var dx: Int
    public var dy: Int
    public init(dx: Int, dy: Int) { self.dx = dx; self.dy = dy }
}

/// マウス履歴 1 世代分 (座標 + 所属モニタ id)。
public struct MouseHistoryEntry: Equatable, Hashable, Sendable {
    public var point: LogicalPoint
    public var displayId: String?
    public init(point: LogicalPoint, displayId: String?) {
        self.point = point
        self.displayId = displayId
    }
}

/// OS から報告される生のディスプレイ配置 (pose は含まない = キャリブレーション情報は
/// displayConfigurationChanged の入力に乗らない。既存の pose は id 一致で引き継ぐ)。
public struct DisplaySnapshot: Equatable, Hashable, Sendable {
    public var id: String
    public var logicalBounds: LogicalRect
    public init(id: String, logicalBounds: LogicalRect) {
        self.id = id
        self.logicalBounds = logicalBounds
    }
}

/// tap 無効化の理由 (DR-0004: timeout/userInput は再有効化、権限失効は degrade)。
public enum TapDisableReason: Equatable, Hashable, Sendable {
    case timeout
    case userInput
    case permissionRevoked
}

/// tap の健全性状態。timeout/userInput は一過性 (再有効化で回復) なので state に残さない。
/// 権限失効のみ「ワープ機能を停止し続ける」永続的な degrade として state に記録する。
public struct TapHealth: Equatable, Hashable, Sendable {
    public var isWarpDisabledByPermissionLoss: Bool
    public init(isWarpDisabledByPermissionLoss: Bool) {
        self.isWarpDisabledByPermissionLoss = isWarpDisabledByPermissionLoss
    }
    public static let healthy = TapHealth(isWarpDisabledByPermissionLoss: false)
}

/// フォーカスフラッシュの直近発火 (DR-0009 Phase A)。
///
/// - `displayId`: フォーカス先モニタの id。App 層は自 overlay がこの id に一致した時のみ縁を光らせる
/// - `generation`: `.focusedDisplayChanged` を受けるたびに単調増加。連続発火 (Cmd-Tab 連打・
///   同一モニタ内のアプリ切替) を「同じ視覚エフェクトを再発火」として区別するためのカウンタ。
///   同じ `displayId` でも `generation` が進めば描画側は新規発火と扱う (DR-0009 「連続切替時は
///   世代カウンタで上書き」)。Store は純関数なので時刻を持たず、フェード進行は描画層 (VM Timer)
///   で管理する。
///
/// Phase B で `windowFrame: LogicalRect?` を追加し、ウィンドウ枠アウトラインの reducer 経路を
/// 開ける想定 (拡張余地は Action.focusedDisplayChanged と対で開けておく)。
public struct FocusFlashState: Equatable, Hashable, Sendable {
    public var displayId: String
    public var generation: UInt64
    public init(displayId: String, generation: UInt64) {
        self.displayId = displayId
        self.generation = generation
    }
}

/// アプリ設定 (Phase 1 の最小プレースホルダ)。Trigger/Judgement が公開しているデフォルト値と
/// 揃えてあるので、設定未変更なら既存の幾何コアのデフォルト挙動と一致する。
public struct AppConfiguration: Equatable, Hashable, Sendable {
    public var edgeEpsilon: Double
    public var warpInwardInsetMillimeters: Double
    public init(edgeEpsilon: Double = Trigger.defaultEdgeEpsilon, warpInwardInsetMillimeters: Double = 0.001) {
        self.edgeEpsilon = edgeEpsilon
        self.warpInwardInsetMillimeters = warpInwardInsetMillimeters
    }
    public static let `default` = AppConfiguration()
}

/// キャリブレーション編集状態。候補 pose はドラッグ中の一時値で、commit するまで確定済み
/// displays/tables には反映されない。
public struct CalibrationState: Equatable, Sendable {
    /// ドラッグ中のモニタ id (ドラッグしていなければ nil)
    public var draggingDisplayId: String?
    /// モニタ id ごとの候補 pose (dragStart で確定済み pose を初期値として持ち込む)
    public var candidatePoses: [String: DisplayPose]
    /// `.preview` action で明示的に再構築される、候補 pose 適用後のプレビュー用テーブル。
    /// 毎 dragMove では再構築しない (DR-0004 の「派生テーブルは特定 action でのみ再構築」に
    /// キャリブレーション編集でも同じ規律を適用する。dragMove は候補値の更新のみ)。
    public var previewTables: WarpTables?

    public init(draggingDisplayId: String?, candidatePoses: [String: DisplayPose], previewTables: WarpTables?) {
        self.draggingDisplayId = draggingDisplayId
        self.candidatePoses = candidatePoses
        self.previewTables = previewTables
    }

    public static let idle = CalibrationState(draggingDisplayId: nil, candidatePoses: [:], previewTables: nil)

    /// 確定済み displays に候補 pose を適用した派生 displays (プレビュー描画専用、判定には使わない)。
    public func previewDisplays(basedOn displays: [Display]) -> [Display] {
        displays.map { d in
            guard let candidate = candidatePoses[d.id] else { return d }
            return Display(id: d.id, logicalBounds: d.logicalBounds, pose: candidate)
        }
    }
}

/// 唯一の source of truth (DR-0004)。
public struct AppState: Equatable, Sendable {
    public var displays: [Display]
    public var userSegments: [PassSegment]
    /// 現構成に対応する display を失った userSegments (DR-0007 決定 7 の inactive)。
    /// reconcile で分離保持され、判定 (WarpTables) からは除外される。UI 可視化は
    /// キャリブレーション UI の次ラウンドで扱うが、Phase 1 でも state 上には保持する
    /// (モニタを一時的に外しただけで設定が失われないため)。
    public var inactiveUserSegments: [PassSegment]
    /// displays/userSegments からのみ導出される derived state。displayConfigurationChanged と
    /// calibration(.commit) の reduce でのみ再構築する。
    public private(set) var tables: WarpTables
    public var previousMouse: MouseHistoryEntry?
    public var currentMouse: MouseHistoryEntry?
    public var configuration: AppConfiguration
    public var calibration: CalibrationState
    public var tapHealth: TapHealth
    /// フォーカスフラッシュ直近発火 (DR-0009 Phase A)。まだ一度も発火していなければ nil。
    /// 描画層は generation の変化を検知して短時間ハイライトを立ち上げ、フェード自体は描画層で管理する。
    public var focusFlash: FocusFlashState?

    public init(
        displays: [Display],
        userSegments: [PassSegment],
        inactiveUserSegments: [PassSegment] = [],
        previousMouse: MouseHistoryEntry? = nil,
        currentMouse: MouseHistoryEntry? = nil,
        configuration: AppConfiguration = .default,
        calibration: CalibrationState = .idle,
        tapHealth: TapHealth = .healthy,
        focusFlash: FocusFlashState? = nil
    ) {
        self.displays = displays
        self.userSegments = userSegments
        self.inactiveUserSegments = inactiveUserSegments
        self.tables = WarpTables(displays: displays, userSegments: userSegments)
        self.previousMouse = previousMouse
        self.currentMouse = currentMouse
        self.configuration = configuration
        self.calibration = calibration
        self.tapHealth = tapHealth
        self.focusFlash = focusFlash
    }

    /// displays/userSegments を書き換えつつ tables を同期して再構築する。同一モジュール内の
    /// Store.reduce 専用 (displayConfigurationChanged / calibration(.commit) のみが呼ぶ)。
    mutating func replaceDisplaysAndRebuildTables(_ newDisplays: [Display]) {
        displays = newDisplays
        tables = WarpTables(displays: newDisplays, userSegments: userSegments)
    }

    /// 永続設定がまだ無い新規構成の初期状態を作る (DR-0006 決定 5)。userSegments を空集合で
    /// 初期化すると全継ぎ目が「os あり・user なし = PB」になり、アプリが OS のネイティブ通過を
    /// 能動的にブロックしてしまう (2026-07-10 実機で発現: 継ぎ目の真ん中で詰まるが角沿いだけ
    /// 通れる、という症状で観測された)。デフォルトは「OS の挙動を変えない」= osPassSegments の
    /// コピーで userSegments を初期化する。
    public static func initial(displays: [Display]) -> AppState {
        AppState(displays: displays, userSegments: Adjacency.detectOSPassSegments(displays))
    }
}
