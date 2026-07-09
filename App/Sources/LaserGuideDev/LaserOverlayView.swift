// LaserOverlayView — 自ディスプレイの 4 隅からポインタへレーザーを描く SwiftUI ビュー。
//
// 2026-07-10 実機フィードバック反映 (#1 / #2 / #3 / #4、詳細は LaserGeometry.swift の
// ヘッダコメント):
//
//   #1 自ディスプレイの 4 角のみを起点にする (他ディスプレイの角の延長線は描かない)
//   #2 ポインタ移動停止後 `OverlayViewModel.inactivityThreshold` 経過でレーザーを非表示
//   #3 corner (幅 cornerHalfWidth*2) が底辺、ポインタから standoff 手前が幅 tipHalfWidth*2
//      の頂点辺となるテーパー付き三角形。ポインタに触れない
//   #4 pose を経由せず CG global 論理座標のまま self bounds を減算して view local を得る
//      (Phase 1 で cross-display の mm 空間が共有されていない前提から根本的に修正)
//
// 描画境界の変換規則 (DR-0005 決定 2):
//   - 判定・state は CG y-down グローバル
//   - view local への変換: global.x - display.bounds.minX, global.y - display.bounds.minY
//   - SwiftUI Canvas は top-left 原点 y-down なので y-flip 不要
import SwiftUI
import LaserGuideCore
import simd

struct LaserOverlayView: View {
    /// 自ディスプレイの id (state から自分に該当する Display を引くキー)
    let displayId: String
    /// state 購読口
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        Canvas { context, size in
            guard let selfDisplay = model.state.displays.first(where: { $0.id == displayId }) else { return }
            let bounds = selfDisplay.logicalBounds

            // #2 アイドル時は非描画 (移動再開で再表示)。currentMouseLocation は保持したままにし、
            //   再表示時に前回位置から瞬時に描き始める。
            guard model.isMouseActive, let mouseGlobal = model.currentMouseLocation else { return }

            // #1 自ディスプレイの 4 隅のみ。#4 pose を経由しない。
            let target = LaserGeometry.viewLocal(mouseGlobal, in: bounds)
            for corner in LaserGeometry.fourCorners(of: bounds) {
                let start = LaserGeometry.viewLocal(corner, in: bounds)
                drawLaser(context: context, from: start, to: target)
            }
        }
        .drawingGroup(opaque: false, colorMode: .nonLinear)
        .allowsHitTesting(false)
    }

    private func drawLaser(context: GraphicsContext, from corner: CGPoint, to pointer: CGPoint) {
        // #3 ポインタ手前で止めるテーパー: standoff 距離だけ手前に頂点を戻す。
        //   ポインタが角に極端に近いと描画不能 (nil)。
        guard let apex = LaserGeometry.taperApexPoint(
            from: corner, to: pointer, standoff: LaserGeometry.defaultStandoffDistance)
        else { return }

        let s = SIMD2<Float>(Float(corner.x), Float(corner.y))
        let t = SIMD2<Float>(Float(apex.x), Float(apex.y))
        let delta = t - s
        let dist = simd.length(delta)
        guard dist > 1 else { return }

        let n = delta / dist
        let perp = SIMD2<Float>(-n.y, n.x)
        let cornerHalfWidth = Float(LaserGeometry.defaultCornerHalfWidth)
        let tipHalfWidth = Float(LaserGeometry.defaultTipHalfWidth)

        let c1 = s + perp * cornerHalfWidth
        let c2 = s - perp * cornerHalfWidth
        let t1 = t + perp * tipHalfWidth
        let t2 = t - perp * tipHalfWidth

        let path = Path { path in
            path.move(to: CGPoint(x: CGFloat(c1.x), y: CGFloat(c1.y)))
            path.addLine(to: CGPoint(x: CGFloat(t1.x), y: CGFloat(t1.y)))
            path.addLine(to: CGPoint(x: CGFloat(t2.x), y: CGFloat(t2.y)))
            path.addLine(to: CGPoint(x: CGFloat(c2.x), y: CGFloat(c2.y)))
            path.closeSubpath()
        }
        let gradient = Gradient(stops: [
            .init(color: Color.red.opacity(0.85), location: 0.0),
            .init(color: Color.yellow.opacity(0.65), location: 0.35),
            .init(color: Color.white.opacity(0.35), location: 1.0),
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: corner, endPoint: apex))
    }
}
