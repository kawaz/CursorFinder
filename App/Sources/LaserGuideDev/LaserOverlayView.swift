// LaserOverlayView — 自ディスプレイの 4 隅からポインタへレーザーを描く SwiftUI ビュー。
//
// 描画要件 (詳細は LaserGeometry.swift のヘッダコメント):
//
//   #1 自ディスプレイの 4 角のみを起点にする (他ディスプレイの角の延長線は描かない)
//   #2 ポインタ移動停止後 `OverlayViewModel.inactivityThreshold` 経過でレーザーを非表示
//   #3 corner (幅 cornerHalfWidth*2) が底辺、target から `laserStandoffPx` 手前が頂点 (1 点)
//      に集約された完全な三角形。ポインタには触れない (DR-0013 決定 3)
//   #4 pose を経由せず CG global 論理座標のまま self bounds を減算して view local を得る
//      (cross-display の mm 空間が共有されていない前提のため、pose 経由の変換は不整合を招く)
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

    /// フォーカスフラッシュ描画 (DR-0013 決定 1 + 追記): 震源ウィンドウ枠
    /// (`state.focusFlash.windowFrame`) をアウトラインで描画する。モニタまたぎ時は各 overlay が
    /// **自分の display 領域だけを clip** した描画を担当し、境界に沿った辺 (= 実際のウィンドウ枠では
    /// ない辺) が引かれないようにする (DR-0013 追記の C-1 修正)。
    ///
    /// 実装契約:
    /// - 交差判定 (自 display に描くべきものがあるか) は `windowFrameLocalRect` (可視部分の
    ///   bounding box) の nil 判定を使う
    /// - 描画される Rectangle は `windowFrameShiftedToDisplay` が返す **windowFrame 全体**
    ///   (display 起点、負値・display 幅超過を含む) に配置する
    /// - 上に `.frame(width: displayWidth, height: displayHeight)` と `.clipped()` を重ねて
    ///   自 display 外にはみ出た辺 (= 隣 display に continue する部分) を除去する
    ///
    /// これにより、intersection の 4 辺を直接 stroke する旧実装 (C-1 で報告) の「display 境界に
    /// 太い線が乗る」欠陥が構造的に発生しなくなる。
    ///
    /// 減衰 / 色 / 持続時間は SettingsStore.focus flash 系 (旧「モニタ縁」項目) をそのまま流用
    /// (DR-0013 決定 1「initial opacity / duration / color は再利用」)。厚み (`focusFlashStrokeWidth`) /
    /// blur (`focusFlashBlurRadius`) も SettingsStore 経由 (DR-0013 追記 M-1)。
    @ViewBuilder
    private var focusFlashView: some View {
        if let flash = model.focusFlash,
           let windowFrame = model.state.focusFlash?.windowFrame,
           let selfDisplay = model.state.displays.first(where: { $0.id == displayId }),
           windowFrameLocalRect(windowFrame: windowFrame, displayBounds: selfDisplay.logicalBounds) != nil {
            let displayBounds = selfDisplay.logicalBounds
            let drawRect = windowFrameShiftedToDisplay(windowFrame: windowFrame, displayBounds: displayBounds)
            let drawWidth = drawRect.maxX - drawRect.minX
            let drawHeight = drawRect.maxY - drawRect.minY
            let displayWidth = displayBounds.maxX - displayBounds.minX
            let displayHeight = displayBounds.maxY - displayBounds.minY
            // 色は SettingsStore 経由 (DR-0012)。alpha は color.a * flash.opacity の乗算。
            let ff = model.focusFlashColor
            let strokeColor = Color(.sRGB, red: ff.r, green: ff.g, blue: ff.b, opacity: ff.a * flash.opacity)
            let strokeThickness = CGFloat(model.focusFlashStrokeWidth)
            let blurRadius = CGFloat(model.focusFlashBlurRadius)
            // Rectangle を windowFrame 全体 (display 起点、負値含む) に配置。display 外に出た辺は
            // 上の .clipped() で切り取られるため、モニタまたぎ時も display 境界に辺が乗らない。
            ZStack {
                Rectangle()
                    .inset(by: strokeThickness / 2)
                    .stroke(strokeColor, lineWidth: strokeThickness)
                    .blur(radius: blurRadius)
                    .frame(width: drawWidth, height: drawHeight)
                    .position(x: drawRect.minX + drawWidth / 2, y: drawRect.minY + drawHeight / 2)
            }
            .frame(width: displayWidth, height: displayHeight, alignment: .topLeading)
            .clipped()
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
        //
        // DR-0013 追記 M-2: UI Slider は 0...200 で範囲保証されるが、旧 JSON / 手動編集で負値が
        // 入る余地に対する防衛として `max(0, ...)` で clamp する。負値の standoff は幾何的に意味が
        // 無く (target を通り越した先に頂点を作ろうとする)、taperApexPoint の nil 判定を経ずに
        // 描画が破綻し得るため。
        let standoff = CGFloat(max(0, model.laserStandoffPx))
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

/// ウィンドウ枠と自 display の交差部分 (可視部分の bounding box) を view-local 座標系
/// (top-left 原点、px) で返す純関数 (DR-0013 決定 1)。
///
/// **注意 (DR-0013 追記 C-1)**: 本関数の返り値は「display 内の可視部分の bounding box」であって、
/// **描画すべき Rectangle の frame ではない**。この rect の 4 辺を単純に stroke すると、モニタ
/// またぎ時に display 境界に沿った辺 (= 実際のウィンドウ枠ではない側の辺) に線が乗り、両 overlay
/// の境界辺が繋がって「モニタ境界に太い線」となる描画欠陥を生む。描画には
/// `windowFrameShiftedToDisplay` (windowFrame 全体を display 起点にシフトした rect、負値含む) +
/// SwiftUI 側 `.clipped()` を使うこと。
///
/// - `windowFrame`: 震源ウィンドウ全体の CG グローバル rect
/// - `displayBounds`: 自 display の CG グローバル bounds
/// - 返り値: `windowFrame ∩ displayBounds` を `displayBounds.min` で減算した view-local rect。
///   交差が空 (接するだけ含む) の場合は nil (= 自 display に描くべきものが無い、描画スキップ)
///
/// 使い所: 描画対象の有無を判定する (nil ⇒ 描画スキップ) 用途。
/// モニタまたぎのウィンドウはそれぞれの overlay が本関数の nil 判定で自分の描画有無を決める。
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

/// ウィンドウ枠**全体**を自 display の view-local 座標系 (top-left 原点、px) にシフトして返す
/// 描画用の純関数 (DR-0013 追記 C-1)。
///
/// `windowFrameLocalRect` (= intersection、可視部分の bbox) と対をなす。描画側は本関数の返す rect
/// を `Rectangle().stroke(...)` の frame として配置し、SwiftUI の `.frame(width: displayWidth,
/// height: displayHeight).clipped()` で自 display の表示領域 [0, displayWidth] × [0, displayHeight]
/// に切る。この構成により、モニタまたぎ時の「実際のウィンドウ枠でない側の辺」は clip されて描画されず、
/// 反対側の overlay window が担当する辺だけがそちらでレンダされる。
///
/// - `windowFrame`: 震源ウィンドウ全体の CG グローバル rect
/// - `displayBounds`: 自 display の CG グローバル bounds
/// - 返り値: `windowFrame.min/max` を `displayBounds.min` で減算しただけの view-local rect。
///   windowFrame が display 外にはみ出る成分は負値 / display 幅超過値としてそのまま残る (clip は SwiftUI 側)
///
/// 交差なし判定 (= 描画スキップ) は `windowFrameLocalRect` の nil 判定を呼び出し側で使う。
/// 本関数自体は判定機能を持たない (幾何変換だけを純粋に責務化して、テスト意味論を「単純減算の一致」に絞る)。
func windowFrameShiftedToDisplay(windowFrame: LogicalRect, displayBounds: LogicalRect) -> LogicalRect {
    LogicalRect(
        minX: windowFrame.minX - displayBounds.minX,
        minY: windowFrame.minY - displayBounds.minY,
        maxX: windowFrame.maxX - displayBounds.minX,
        maxY: windowFrame.maxY - displayBounds.minY)
}
