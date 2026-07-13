// OverlayViewModel が公開する表示表現 (presentation) 型と、その入力 Action 型。
// VM 本体 (OverlayViewModel.swift) から分離した純データ型のみを置く。
import CoreGraphics
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

/// フォーカスフラッシュ (DR-0009 Phase A + DR-0013 決定 1) の描画表現。overlay ごとに保持する。
///
/// Core (`FocusFlashState`) は「震源ウィンドウの CG global frame」と「連続発火の識別用 generation」
/// を持ち、時刻・フェード進行は描画層 (VM) が管理する (DR-0004 の「Store は純関数、時刻・非決定性を
/// 持ち込まない」を維持するため)。**DR-0013 決定 1 以降、描画対象は震源ウィンドウ枠**であり、
/// モニタ担当判定は `state.focusFlash?.windowFrame` を各 overlay の display bounds で交差判定
/// する形 (LaserOverlayView.focusFlashView) に統一。かつての `displayId` フィールドは
/// 判定に不要になったため廃止 (DR-0013 追記 m-1)。
///
/// - `opacity`: 立ち上がり直後は `initialOpacity`、時間経過で 0 まで減衰
public struct FocusFlashPresentation: Equatable, Sendable {
    public let opacity: Double
    public init(opacity: Double) {
        self.opacity = opacity
    }
}

/// フォーカス波動 (DR-0011 決定 3) の描画表現。overlay 横断で単一のインスタンスを共有する
/// (震源は mm 空間なので、どの overlay も同じ値から自 display の view-local px へ変換して描く)。
///
/// - `epicenterMM`: 震源 (フォーカスウィンドウ frame を mm 空間へ写像した矩形)
/// - `radiusMM`: 震源矩形を外側へ膨張させる距離 (= 角丸矩形リングの角丸半径でもある、DR-0011 決定 3)
/// - `bandMM`: リングの帯幅 (mm)。進行に関わらず一定
/// - `opacity`: 進行度に応じて initialOpacity から 0 へ減衰
public struct WavePresentation: Equatable, Sendable {
    public let epicenterMM: PhysicalRect
    public let radiusMM: Double
    public let bandMM: Double
    public let opacity: Double
    public init(epicenterMM: PhysicalRect, radiusMM: Double, bandMM: Double, opacity: Double) {
        self.epicenterMM = epicenterMM
        self.radiusMM = radiusMM
        self.bandMM = bandMM
        self.opacity = opacity
    }

    /// 進行度 p (0...1) 時点の presentation を Core の WaveGeometry から導出する
    /// (VM 側 Timer tick から呼ぶためのファクトリ、半径・不透明度の式自体は WaveGeometry が正)。
    public static func at(
        progress p: Double, epicenterMM: PhysicalRect, maxDistanceMM: Double, bandMM: Double, initialOpacity: Double
    ) -> WavePresentation {
        WavePresentation(
            epicenterMM: epicenterMM,
            radiusMM: WaveGeometry.radiusMM(progress: p, maxDistanceMM: maxDistanceMM, bandMM: bandMM),
            bandMM: bandMM,
            opacity: WaveGeometry.opacity(progress: p, initialOpacity: initialOpacity)
        )
    }
}

/// 波動描画用の mm → view-local px 変換 (`WavePlacement.localPx` と同一の式を
/// `CGAffineTransform` として組み立てる)。SwiftUI `Path.applying` に食わせるため
/// App 層に切り出し、`OverlayViewModelTests` で `WavePlacement.localPx(fromMM:)` との
/// 一致をテストで固定する (LaserOverlayView にインラインで埋めるとテストできないため)。
func waveMMToLocalTransform(_ placement: WavePlacement) -> CGAffineTransform {
    CGAffineTransform(translationX: -CGFloat(placement.mmRect.minX), y: -CGFloat(placement.mmRect.minY))
        .concatenating(CGAffineTransform(scaleX: CGFloat(1 / placement.scaleX), y: CGFloat(1 / placement.scaleY)))
}
