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
        ZStack {
            Canvas { context, _ in
                guard let selfDisplay = model.state.displays.first(where: { $0.id == displayId }) else { return }
                let bounds = selfDisplay.logicalBounds

                // アイドル時 (laserOpacity=0) は非描画。currentMouseLocation は保持したままにし、
                // 再表示時に前回位置から瞬時に描き始める。フェード中 (0 < opacity < 1) は
                // 下の .opacity() でレーザー全体が減衰して見える。
                guard model.laserOpacity > 0, let mouseGlobal = model.currentMouseLocation else { return }

                // #1 自ディスプレイの 4 隅のみ。#4 pose を経由しない。
                let target = LaserGeometry.viewLocal(mouseGlobal, in: bounds)
                for corner in LaserGeometry.fourCorners(of: bounds) {
                    let start = LaserGeometry.viewLocal(corner, in: bounds)
                    drawLaser(context: context, from: start, to: target)
                }
            }
            .drawingGroup(opaque: false, colorMode: .nonLinear)
            .opacity(model.laserOpacity)
            .allowsHitTesting(false)

            // プレゼンテーションモード時のクリック可視化サークル。off 時 / 減衰完了時は clickCircle=nil で
            // 非描画。VM 側で opacity が段階的に減衰するので、view はそのまま fill opacity として使う
            // (SwiftUI 標準の暗黙 animation に頼らず、AppKit 側 Timer 由来の値変化で見せる)。
            clickCircleView

            // フォーカスフラッシュ (DR-0009 Phase A): フォーカス先モニタの縁を短時間ハイライト。
            // 自 display と focusFlash.displayId が一致した時のみ描画、それ以外の overlay では nil
            // で非描画。opacity は VM 側 Timer で減衰済み、view は fill/stroke opacity として使う。
            focusFlashView

            // フォーカス波動 (DR-0011): ウィンドウ枠を震源に mm 空間で拡がるリング。DR-0011 決定 5
            // により上のモニタ縁フラッシュと併存する (波動が主役)。
            waveView
        }
    }

    /// フォーカス波動描画 (DR-0011 決定 3): 震源矩形 (mm) を radiusMM 外側へ膨張した角丸矩形の
    /// **帯 (リング)** を mm 空間で作ってから、`waveMMToLocalTransform` (mm → 自 display 基準
    /// view-local px、`WavePlacement.localPx` と同じ式) を適用して fill する。帯そのものを mm
    /// 空間で `strokedPath(StrokeStyle(lineWidth: bandMM))` により生成するため、帯幅は写像後の
    /// px 単位 stroke ではなく物理量 (mm) として厳密になる (= 混合 DPI/異方 scale でも帯幅が
    /// 方向によって変わらない)。波は複数 display にまたがって拡がるため、自 display の
    /// placement を `model.wavePlacements` から引いて初めて描画できる (state.displays からの
    /// 毎 tick 再構築ではなく発火時スナップショットを使うのは OverlayViewModel.startWave の
    /// コメント参照)。
    @ViewBuilder
    private var waveView: some View {
        if let wave = model.wave,
           let placement = model.wavePlacements.first(where: { $0.displayId == displayId }) {
            let expandedMM = CGRect(
                x: CGFloat(wave.epicenterMM.minX - wave.radiusMM),
                y: CGFloat(wave.epicenterMM.minY - wave.radiusMM),
                width: CGFloat(wave.epicenterMM.width + wave.radiusMM * 2),
                height: CGFloat(wave.epicenterMM.height + wave.radiusMM * 2)
            )
            let ringMM = Path(roundedRect: expandedMM, cornerRadius: CGFloat(max(0, wave.radiusMM)))
                .strokedPath(StrokeStyle(lineWidth: CGFloat(wave.bandMM)))
            let localPath = ringMM.applying(waveMMToLocalTransform(placement))
            // 色は SettingsStore 経由の model.waveColor が単一情報源 (DR-0012)。alpha 成分は
            // 設定値 * 波動 progress の opacity として掛け合わせる。
            let base = model.waveColor
            localPath
                .fill(Color(.sRGB, red: base.r, green: base.g, blue: base.b, opacity: base.a * wave.opacity))
                .allowsHitTesting(false)
        }
    }

    /// フォーカスフラッシュ描画 (DR-0009 Phase A): 対象モニタの内側に向けたブルー系グローで縁を強調。
    /// 厚み・色の根拠は clickCircle と同様の実機フィードバックで再調整前提の初期値:
    /// - 色: `systemBlue` (macOS のアクセント色に近く、システムのフォーカス強調と親和性が高い)
    /// - 厚み: 内側 24px の枠 + 8px blur。ウィンドウ枠ハイライト (Phase B) と重なった時にも
    ///   モニタ縁の方が薄く広く光る差別化ができる
    /// - フェード: VM 側 focusFlashDuration=0.5s (task 指示 ~0.5s に沿う)
    @ViewBuilder
    private var focusFlashView: some View {
        if let flash = model.focusFlash, flash.displayId == displayId,
           let selfDisplay = model.state.displays.first(where: { $0.id == displayId }) {
            let width = selfDisplay.logicalBounds.maxX - selfDisplay.logicalBounds.minX
            let height = selfDisplay.logicalBounds.maxY - selfDisplay.logicalBounds.minY
            let strokeThickness: CGFloat = 24
            // 色は SettingsStore 経由 (DR-0012)。alpha は color.a * flash.opacity の乗算。
            let ff = model.focusFlashColor
            let strokeColor = Color(.sRGB, red: ff.r, green: ff.g, blue: ff.b, opacity: ff.a * flash.opacity)
            Rectangle()
                .inset(by: strokeThickness / 2)
                .stroke(strokeColor, lineWidth: strokeThickness)
                .blur(radius: 8)
                .frame(width: width, height: height)
                .position(x: width / 2, y: height / 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var clickCircleView: some View {
        if let click = model.clickCircle,
           let selfDisplay = model.state.displays.first(where: { $0.id == displayId }) {
            let bounds = selfDisplay.logicalBounds
            let local = LaserGeometry.viewLocal(click.point, in: bounds)
            // 対象モニタ外の click は描画しない (view 外に位置指定しても実害は無いが、透明矩形の
            // 描画コストを避ける)。
            let inside = local.x >= 0 && local.y >= 0
                && local.x <= (bounds.maxX - bounds.minX)
                && local.y <= (bounds.maxY - bounds.minY)
            if inside {
                Circle()
                    .fill(Color.white.opacity(click.opacity))
                    .overlay(
                        Circle().strokeBorder(
                            Color.blue.opacity(min(1.0, click.opacity + 0.2)),
                            lineWidth: 3)
                    )
                    .frame(width: 60, height: 60)
                    .position(local)
                    .allowsHitTesting(false)
            }
        }
    }

    private func drawLaser(context: GraphicsContext, from corner: CGPoint, to pointer: CGPoint) {
        // #3 ポインタ手前で止めるテーパー: standoff は角→ポインタ距離の比率 (+ min/max クランプ) で
        //   決める (2026-07-10 第 2 ラウンド、固定 40px から変更)。ポインタが角に極端に近いと描画不能 (nil)。
        let dx = pointer.x - corner.x
        let dy = pointer.y - corner.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let standoff = LaserGeometry.standoffDistance(cornerToTargetDistance: distance)
        guard let apex = LaserGeometry.taperApexPoint(from: corner, to: pointer, standoff: standoff)
        else { return }

        let s = SIMD2<Float>(Float(corner.x), Float(corner.y))
        let t = SIMD2<Float>(Float(apex.x), Float(apex.y))
        let delta = t - s
        let dist = simd.length(delta)
        guard dist > 1 else { return }

        let n = delta / dist
        let perp = SIMD2<Float>(-n.y, n.x)
        // DR-0012: 太さは SettingsStore 経由の model 値が単一情報源。LaserGeometry の default
        // 定数は SettingsStore の初期値としてのみ参照する (実描画には使わない)。
        let cornerHalfWidth = Float(model.laserCornerHalfWidth)
        let tipHalfWidth = Float(model.laserTipHalfWidth)

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
        // DR-0012: グラデーション 3 stop は SettingsStore 経由の model 値が単一情報源。
        // location (0.0 / 0.35 / 1.0) は現状固定 (色 stop の追加は Phase 2 検討)。
        func gradientColor(_ c: RGBAColor) -> Color {
            Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }
        let gradient = Gradient(stops: [
            .init(color: gradientColor(model.laserColorNear), location: 0.0),
            .init(color: gradientColor(model.laserColorMid), location: 0.35),
            .init(color: gradientColor(model.laserColorFar), location: 1.0)
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: corner, endPoint: apex))
    }
}
