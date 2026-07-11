// OverlayViewModel が公開する表示表現 (presentation) 型と、その入力 Action 型。
// VM 本体 (OverlayViewModel.swift) から分離した純データ型のみを置く。
import LaserGuideCore

/// プレゼンテーションモード時にオーバーレイへ流し込む click 表現の Action 型。
/// NSEvent global monitor 由来の生イベントを AppDelegate で本型に変換して VM に流す
/// (= issue 2026-07-10-presentation-mode-capture-toggle.md「Action として形式化」の要件)。
///
/// Core.Action ではなく App 層の Action にしている理由: click 可視化はワープ判定や永続化に
/// 影響しない純粋な表示専用イベントで、AppState の source of truth に含める必要が無い。
/// DR-0004 の「描画は state 購読」を狭義に守るために Core を膨らませるより、App 層の VM に
/// 明示的な入力口を用意する方が Phase 1 のコストに見合う (Core Action への昇格は Phase 2)。
public struct PresentationClickEvent: Equatable, Sendable {
    /// 2026-07-10 実機フィードバック第 2 ラウンド #2: `drag` はボタンを押している間の位置更新。
    /// down で表示開始したサークルの `point` だけを更新し、opacity は変えない
    /// (= ドラッグ中は消えずカーソルに追従、離した位置から減衰が始まる)。
    public enum Phase: Equatable, Sendable { case down, drag, up }
    public let phase: Phase
    public let point: LogicalPoint
    public init(phase: Phase, point: LogicalPoint) {
        self.phase = phase
        self.point = point
    }
}

/// クリック可視化サークルの表示状態 (プレゼンテーションモード on 時のみ描画される)。
public struct ClickCirclePresentation: Equatable, Sendable {
    public let point: LogicalPoint
    /// 0.0 = 完全透明、1.0 = 完全不透明。mouseDown で initial 値、mouseUp 後に段階的に減衰する。
    public let opacity: Double
    public init(point: LogicalPoint, opacity: Double) {
        self.point = point
        self.opacity = opacity
    }
}

/// フォーカスフラッシュ (DR-0009 Phase A) の描画表現。overlay ごとに保持する。
///
/// Core (`FocusFlashState`) は「どのモニタに向けてフラッシュを立てたか」と「連続発火の識別用
/// generation」だけを持ち、時刻・フェード進行は描画層 (VM) が管理する (DR-0004 の「Store は
/// 純関数、時刻・非決定性を持ち込まない」を維持するため)。
/// - `displayId`: フォーカス先のモニタ id。LaserOverlayView は自 display と一致した時のみ縁を描く
/// - `opacity`: 立ち上がり直後は `initialOpacity`、時間経過で 0 まで減衰
public struct FocusFlashPresentation: Equatable, Sendable {
    public let displayId: String
    public let opacity: Double
    public init(displayId: String, opacity: Double) {
        self.displayId = displayId
        self.opacity = opacity
    }
}
