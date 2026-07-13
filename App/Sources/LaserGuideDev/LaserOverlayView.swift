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

    /// フォーカスフラッシュ描画 (DR-0013): 震源ウィンドウ枠 (`state.focusFlash.windowFrame`) を
    /// 自 display と交差する部分だけアウトライン描画する (旧「モニタ内側 stroke + blur」を廃止)。
    ///
    /// モニタまたぎ時は各 overlay が自分の担当部分だけを描くため、`FocusFlashPresentation.displayId`
    /// による判定はしない (震源 display と別の overlay でも windowFrame が自 display に重なれば描画対象)。
    /// `windowFrameLocalRect` が交差計算 + view-local 変換を一手に担い、非交差 (nil) なら描画しない。
    ///
    /// 減衰 / 色 / 持続時間は SettingsStore.focus flash 系 (旧「モニタ縁」項目) をそのまま流用
    /// (DR-0013 決定 1「initial opacity / duration / color は再利用」)。厚み・blur は kawaz 実機
    /// フィードバックで再調整前提の初期値: 内側 6px + blur 3px (旧 24px + 8px からウィンドウ枠に
    /// 適したスケールへ縮小)。
    @ViewBuilder
    private var focusFlashView: some View {
        if let flash = model.focusFlash,
           let windowFrame = model.state.focusFlash?.windowFrame,
           let selfDisplay = model.state.displays.first(where: { $0.id == displayId }),
           let localRect = windowFrameLocalRect(windowFrame: windowFrame, displayBounds: selfDisplay.logicalBounds) {
            let width = localRect.maxX - localRect.minX
            let height = localRect.maxY - localRect.minY
            // 色は SettingsStore 経由 (DR-0012)。alpha は color.a * flash.opacity の乗算。
            let ff = model.focusFlashColor
            let strokeColor = Color(.sRGB, red: ff.r, green: ff.g, blue: ff.b, opacity: ff.a * flash.opacity)
            let strokeThickness: CGFloat = 6
            Rectangle()
                .inset(by: strokeThickness / 2)
                .stroke(strokeColor, lineWidth: strokeThickness)
                .blur(radius: 3)
                .frame(width: width, height: height)
                .position(x: localRect.minX + width / 2, y: localRect.minY + height / 2)
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
        // #3 DR-0013: standoff は SettingsStore `laserStandoffPx` (px 固定値、既定 40) を直接使う。
        // 頂点辺半幅 tipHalfWidth は 0 に固定 (path は 3 頂点の完全な三角形)。ポインタが角から
        // standoff+minLength 以下の距離だと taperApexPoint が nil を返し描画不能扱い。
        let standoff = CGFloat(model.laserStandoffPx)
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

        let c1 = s + perp * cornerHalfWidth
        let c2 = s - perp * cornerHalfWidth

        // DR-0013: 頂点 1 点集約 — c1 → apex → c2 の 3 頂点で完全な三角形を描く
        // (旧実装は tipHalfWidth*2 の頂点辺を持つ 4 頂点の台形)。
        let path = Path { path in
            path.move(to: CGPoint(x: CGFloat(c1.x), y: CGFloat(c1.y)))
            path.addLine(to: apex)
            path.addLine(to: CGPoint(x: CGFloat(c2.x), y: CGFloat(c2.y)))
            path.closeSubpath()
        }
        // DR-0013: グラデーション 2 stop (角 near / ポインタ側 far)。旧 mid (location 0.35) 廃止で
        // 単純な線形ブレンドに戻す (SettingsStore 経由の model 値が単一情報源、DR-0012)。
        func gradientColor(_ c: RGBAColor) -> Color {
            Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }
        let gradient = Gradient(stops: [
            .init(color: gradientColor(model.laserColorNear), location: 0.0),
            .init(color: gradientColor(model.laserColorFar), location: 1.0)
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: corner, endPoint: apex))
    }
}

/// ウィンドウ枠 (CG グローバル論理座標) を自 display の view-local 座標系 (top-left 原点、px)
/// にクリップして返す純関数 (DR-0013 決定 1)。
///
/// - `windowFrame`: 震源ウィンドウ全体の CG グローバル rect
/// - `displayBounds`: 自 display の CG グローバル bounds
/// - 返り値: `windowFrame ∩ displayBounds` を `displayBounds.min` で減算した view-local rect。
///   交差が空 (接するだけ含む) の場合は nil (= 自 display に描くべきものが無い)
///
/// モニタまたぎのウィンドウはそれぞれの overlay が本関数で自分の担当部分を計算し、非交差の
/// overlay は描画をスキップする (LaserOverlayView.focusFlashView が判定に使う)。
func windowFrameLocalRect(windowFrame: LogicalRect, displayBounds: LogicalRect) -> LogicalRect? {
    let minX = max(windowFrame.minX, displayBounds.minX)
    let minY = max(windowFrame.minY, displayBounds.minY)
    let maxX = min(windowFrame.maxX, displayBounds.maxX)
    let maxY = min(windowFrame.maxY, displayBounds.maxY)
    // 空 (幅 or 高さ 0 以下) の交差は「重ならない」扱い。境界で接するだけのケースも nil。
    guard minX < maxX, minY < maxY else { return nil }
    return LogicalRect(
        minX: minX - displayBounds.minX,
        minY: minY - displayBounds.minY,
        maxX: maxX - displayBounds.minX,
        maxY: maxY - displayBounds.minY)
}
