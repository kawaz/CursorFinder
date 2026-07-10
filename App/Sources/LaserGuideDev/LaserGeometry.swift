// LaserGeometry — レーザー描画に使う純関数群 (App 層の pure モジュール)
//
// - SwiftUI / AppKit に依存しない座標算術のみ (CGPoint / CGFloat は使う)
// - LaserOverlayView からの経路と App/Tests からのユニットテストの両方から使う
//
// 2026-07-10 実機フィードバック #1 / #3 / #4 の修正で新設:
//
//   #1 「各モニタは自分の 4 角からのレーザーだけ描く」
//     → 四隅の列挙は自ディスプレイの logicalBounds のみを対象にする。
//        他ディスプレイの角からの延長線は描画しない。
//
//   #3 「ポインタ手前で止まる三角形」
//     → corner (幅 cornerHalfWidth*2) が底辺、standoff だけポインタから手前に引いた
//        位置に幅 tipHalfWidth*2 の頂点辺を作る台形 (実質テーパー付き三角形)。
//        `taperApexPoint` は「ポインタから standoff だけ corner 側に戻した点」を返す。
//
//   #4 「境界でレーザー焦点が残るバグの根本原因」
//     旧 LaserOverlayView は `mouseDisplay.pose.toPhysical → selfDisplay.pose.toLogical`
//     経由でポインタ位置を self overlay の描画空間へ変換していた。しかし Phase 1 の
//     DisplaySnapshotProvider は各ディスプレイの pose を translate=0 で作るため、
//     display ごとに独立した mm frame を持つ (cross-display の物理継ぎ目連続は
//     キャリブレーション UI 実装まで整えないという明示的な Phase 1 判断)。
//     この状態で異なる display の pose を経由して mm → logical 変換すると、
//     「同じ CG global point が経路の source display によって別の描画位置に落ちる」
//     不整合が起きる。継ぎ目跨ぎの際、mouseDisplay が built-in ↔ LG で切り替わるたび
//     描画位置が scale 比 (source scale / self scale ≒ 0.55) で圧縮された値に跳ぶため、
//     ジリジリした微小移動として現れる (2026-07-10 kawaz 実機報告 #4)。
//
//     修正: CG global 論理座標は既にすべてのディスプレイで共有された基準座標系である
//     ため、pose を経由せず単純減算で view local へ落とすのが正しい。物理 mm 空間を
//     経由した cross-display 直進性の担保は Phase 2 (共有 mm 原点を持つキャリブレーション
//     UI) の課題として明示的に切り出す。
import Foundation
import CoreGraphics
import LaserGuideCore

public enum LaserGeometry {

    /// 角側の底辺半幅 (px)。v1 と同値。
    public static let defaultCornerHalfWidth: CGFloat = 8.0
    /// ポインタ手前の頂点辺半幅 (px)。v1 と同値。
    public static let defaultTipHalfWidth: CGFloat = 0.5

    /// standoff (ポインタ手前で止めるオフセット) を「角→ポインタ距離の何 % 引いた位置を頂点にするか」
    /// の比率で決める。頂点は距離の (1 - defaultStandoffRatio) = 90% の位置になる。
    /// 2026-07-10 第 2 ラウンド フィードバック #3: 固定 40px だと極端に短い/長いレーザーで
    /// 見た目のバランスが崩れる (短いと標準に対して比率が大きすぎる、長いと相対的に小さすぎる) ため
    /// 距離に比例させる。ただし比例のみだと退化するので min/max で px クランプする。
    public static let defaultStandoffRatio: CGFloat = 0.1
    /// standoff の下限 (px)。距離が短いレーザーでも標準が潰れないようにする。
    public static let minStandoffDistance: CGFloat = 8.0
    /// standoff の上限 (px)。距離が長いレーザーで standoff が過大にならないようにする。
    public static let maxStandoffDistance: CGFloat = 200.0

    /// corner→target の距離から実際に使う standoff (px) を、比率 + min/max クランプで求める。
    /// `taperApexPoint(standoff:)` 自体は「与えられた standoff 距離だけ手前に戻す」純粋な幾何計算の
    /// ままにし (既存呼び出し・既存テストの意味を変えない)、standoff の値そのものをどう決めるかを
    /// この関数に分離する。
    public static func standoffDistance(
        cornerToTargetDistance distance: CGFloat,
        ratio: CGFloat = defaultStandoffRatio,
        min minStandoff: CGFloat = minStandoffDistance,
        max maxStandoff: CGFloat = maxStandoffDistance
    ) -> CGFloat {
        Swift.min(Swift.max(distance * ratio, minStandoff), maxStandoff)
    }

    /// 自ディスプレイの 4 隅 (CG global 論理座標)。
    /// 2026-07-10 フィードバック #1: 描画は自ディスプレイの 4 隅からのみ。
    public static func fourCorners(of r: LogicalRect) -> [LogicalPoint] {
        [
            LogicalPoint(x: r.minX, y: r.minY),
            LogicalPoint(x: r.maxX, y: r.minY),
            LogicalPoint(x: r.minX, y: r.maxY),
            LogicalPoint(x: r.maxX, y: r.maxY)
        ]
    }

    /// CG global 論理座標 (px) → 自 overlay canvas 座標 (top-left 原点、px)。
    /// pose を経由しない (フィードバック #4 の根本原因回避)。
    public static func viewLocal(_ p: LogicalPoint, in bounds: LogicalRect) -> CGPoint {
        CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)
    }

    /// テーパー付き三角形の頂点 (apex) 座標。
    ///
    /// corner → target 方向に、target から standoff だけ手前に戻した点を返す。
    /// target が corner に対して standoff より近い場合は描画不能として nil を返す
    /// (ゼロ長線 / 反転を避ける)。
    public static func taperApexPoint(from corner: CGPoint, to target: CGPoint, standoff: CGFloat) -> CGPoint? {
        let dx = target.x - corner.x
        let dy = target.y - corner.y
        let dist = (dx * dx + dy * dy).squareRoot()
        // standoff より短い距離 (= ポインタが角に極端に近い) では描画しない。
        // 最小長 1px を加えて 0 割 / 極短辺の破綻を避ける。
        let minLength: CGFloat = 1.0
        guard dist > standoff + minLength else { return nil }
        let t = (dist - standoff) / dist
        return CGPoint(x: corner.x + dx * t, y: corner.y + dy * t)
    }
}
