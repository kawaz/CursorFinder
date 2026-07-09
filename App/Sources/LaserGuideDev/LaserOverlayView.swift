// LaserOverlayView (v1 の四隅→カーソル描画を物理 mm 空間で計算する版、DR-0005)
//
// 各オーバーレイは自ディスプレイに張り付き、以下を描画する:
//   1. 全ディスプレイの 4 隅を **物理 mm** で列挙する (自ディスプレイの corner だけでなく)
//   2. マウス位置を「マウスの居るディスプレイの pose」で mm へ変換する
//   3. 各 corner (mm) → マウス (mm) の直線を、自ディスプレイの pose.toLogical で自ディス
//      プレイの論理座標へ戻し、自ディスプレイのローカル canvas 座標へ変換して描画
//
// 座標境界 (DR-0005 決定 2 の描画境界規則):
//   - 判定・state は CG y-down グローバル
//   - view local への変換は「global.x - display.bounds.minX, global.y - display.bounds.minY」
//   - SwiftUI Canvas は top-left 原点 y-down なので y-flip 不要 (NSHostingView が処理)
//     (v1 は NSEvent 由来の y-up 座標を使っていたため canvas 内で y-flip していた。v3 は
//     CGEvent 由来 y-down で統一しているので flip 不要)
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

            // 自ディスプレイ内での「マウスの物理位置」を得るために、まずマウスの居るディスプレイを特定。
            // 権限 fallback (NSEvent monitor) 経由も含めた最新位置を model が保持している。
            guard let mouseGlobal = model.currentMouseLocation else { return }
            guard let mouseDisplay = displayContaining(mouseGlobal, in: model.state.displays)
                ?? nearestDisplay(mouseGlobal, in: model.state.displays)
            else { return }
            let mousePhysical = mouseDisplay.pose.toPhysical(mouseGlobal)

            // 各ディスプレイの 4 隅を mm へ落とし、自ディスプレイの canvas へ戻す。
            for d in model.state.displays {
                for corner in fourCorners(of: d.logicalBounds) {
                    let cornerPhysical = d.pose.toPhysical(corner)
                    // 自ディスプレイ pose での逆変換 (画面越しに continuous な mm 線を per-display の
                    // 論理空間へ落とす経路。CG global logical へは戻さない — 自ディスプレイの pose を
                    // 直接 mm→own logical に使う)。
                    let startInSelfLogical = selfDisplay.pose.toLogical(cornerPhysical)
                    let mouseInSelfLogical = selfDisplay.pose.toLogical(mousePhysical)

                    let p0 = viewLocal(startInSelfLogical, bounds: bounds)
                    let p1 = viewLocal(mouseInSelfLogical, bounds: bounds)

                    // 自 canvas 外は描画しない (SwiftUI Canvas がクリップ) — 極端に長い線でも安全。
                    drawLaser(context: context, from: p0, to: p1)
                }
            }
        }
        .drawingGroup(opaque: false, colorMode: .nonLinear)
        .allowsHitTesting(false)
    }

    // ================================
    // 描画補助
    // ================================

    private func fourCorners(of r: LogicalRect) -> [LogicalPoint] {
        [
            LogicalPoint(x: r.minX, y: r.minY),
            LogicalPoint(x: r.maxX, y: r.minY),
            LogicalPoint(x: r.minX, y: r.maxY),
            LogicalPoint(x: r.maxX, y: r.maxY),
        ]
    }

    private func viewLocal(_ p: LogicalPoint, bounds: LogicalRect) -> CGPoint {
        CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)
    }

    private func displayContaining(_ p: LogicalPoint, in displays: [Display]) -> Display? {
        displays.first(where: { $0.logicalBounds.containsHalfOpen(p) })
    }

    /// 半開区間包含から漏れた境界点向けの近傍フォールバック。中心距離で選ぶ。
    private func nearestDisplay(_ p: LogicalPoint, in displays: [Display]) -> Display? {
        displays.min(by: { a, b in
            centerDist2(p, a.logicalBounds) < centerDist2(p, b.logicalBounds)
        })
    }

    private func centerDist2(_ p: LogicalPoint, _ r: LogicalRect) -> Double {
        let cx = (r.minX + r.maxX) / 2
        let cy = (r.minY + r.maxY) / 2
        let dx = p.x - cx; let dy = p.y - cy
        return dx * dx + dy * dy
    }

    private func drawLaser(context: GraphicsContext, from p0: CGPoint, to p1: CGPoint) {
        let s = SIMD2<Float>(Float(p0.x), Float(p0.y))
        let t = SIMD2<Float>(Float(p1.x), Float(p1.y))
        let delta = t - s
        let dist = simd.length(delta)
        guard dist > 1 else { return }

        let n = delta / dist
        let perp = SIMD2<Float>(-n.y, n.x)
        let cornerHalfWidth: Float = 8
        let targetHalfWidth: Float = 0.5

        let c1 = s + perp * cornerHalfWidth
        let c2 = s - perp * cornerHalfWidth
        let t1 = t + perp * targetHalfWidth
        let t2 = t - perp * targetHalfWidth

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
        context.fill(path, with: .linearGradient(gradient, startPoint: p0, endPoint: p1))
    }
}
