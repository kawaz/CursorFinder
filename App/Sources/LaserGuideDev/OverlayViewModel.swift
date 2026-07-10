// OverlayViewModel (DR-0004: 描画は state 購読、individual action を舐めない)
//
// AppRuntime.stateDidChange と、権限 fallback 時の NSEvent monitor からの mouse 位置更新を
// 1 か所にまとめ、SwiftUI ObservableObject として overlay に流す。
//
// 現在マウス位置の source of truth:
//   - 権限あり (通常経路): AppRuntime.state.currentMouse (Store が更新する)
//   - 権限なし (fallback): NSEvent global monitor (permission fallback 起動時のみ購読)
// どちらも同じ CG y-down 論理座標として `currentMouseLocation` に反映される。
//
// 2026-07-10 フィードバック #2 (アイドルフェード):
//   ポインタ移動が停止したら inactivityThreshold 経過後にレーザーを非表示にする
//   (v1 の debounce 0.3s と同等)。位置変化時のみ debounce をリセットして再表示。
//
// 2026-07-10 第 2 ラウンド フィードバック #5 (描画更新の 60Hz 合流):
//   tap 経由 (apply(state:)) も drag monitor 経由 (apply(mouseLocation:)) も、OS のイベント
//   レポートレートに比例した高頻度で呼ばれうる。毎回 @Published を発火すると SwiftUI の
//   再評価コストがイベントレートに比例して積み重なり、ドラッグ操作の体感が重くなる
//   (kawaz 実機報告: レーザー非表示中でもドラッグが重かった → @Published の発火自体が
//   コストの主因という仮説)。両経路とも「最新値を保持するだけ」の軽い代入にとどめ、
//   実際の @Published 反映は 16ms (60Hz) ごとの coalesce タイマーでまとめて行う。
import Foundation
import AppKit
import Combine
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
    public enum Phase: Equatable, Sendable { case down, up }
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

public final class OverlayViewModel: ObservableObject {
    @Published public var state: AppState
    @Published public var currentMouseLocation: LogicalPoint?
    /// #2 アイドルフェード: 直近 inactivityThreshold の間にマウス移動があったか。
    /// false の間、LaserOverlayView は描画をスキップする。
    @Published public var isMouseActive: Bool = false
    /// プレゼンテーションモード on 時のクリック可視化。off 時 / mouseUp 後の減衰完了時は nil。
    @Published public var clickCircle: ClickCirclePresentation?
    /// フォーカスフラッシュ (DR-0009 Phase A) の現在描画状態。
    /// state.focusFlash の generation 変化を検知して立ち上げ、focusFlashDuration にかけて減衰する。
    /// 減衰完了時 / focus flash 機能 off 時は nil。
    @Published public var focusFlash: FocusFlashPresentation?

    /// ポインタ移動停止からレーザーを消すまでの猶予 (v1 の Config.Timing.inactivityThreshold=0.3 と同値)。
    public var inactivityThreshold: TimeInterval = 0.3

    /// coalesce タイマーの周期 (60Hz = 約16.67ms)。テストで注入できるよう var にしておく。
    public var flushInterval: TimeInterval = 1.0 / 60.0

    /// mouseUp 後のクリックサークル消滅時間 (秒)。テスト用に注入可能。
    public var clickFadeDuration: TimeInterval = 0.3
    /// mouseDown 時のサークル初期不透明度。
    public var clickInitialOpacity: Double = 0.6

    /// フォーカスフラッシュのフェード時間 (秒)。task 指示「~0.5s でフェードアウト」に沿う。
    public var focusFlashDuration: TimeInterval = 0.5
    /// フォーカスフラッシュの初期不透明度。0.6 前後にすることでシステム標準の accent 系ハイライトと
    /// 近い体感になる (実機フィードバックで再調整余地あり)。
    public var focusFlashInitialOpacity: Double = 0.6

    private var inactivityWorkItem: DispatchWorkItem?
    private var pendingState: AppState?
    private var pendingMouseLocation: LogicalPoint?
    private var flushTimer: Timer?
    private var clickFadeTimer: Timer?
    private var focusFlashFadeTimer: Timer?
    /// 直近で立ち上げた focus flash の generation。次回 apply(state:) 時に state.focusFlash?.generation
    /// と比較し、増えていれば新規発火として立ち上げ直す (同一 displayId でも再発火する)。
    private var lastFocusFlashGeneration: UInt64 = 0

    public init(initialState: AppState, initialMouse: LogicalPoint? = nil) {
        self.state = initialState
        self.currentMouseLocation = initialMouse
        // 初期 state 時点で focusFlash が既にセットされていても VM 生成時に「見なかった発火」を
        // 立ち上げないよう、last カウンタを synchronize しておく (通常は 0)。
        self.lastFocusFlashGeneration = initialState.focusFlash?.generation ?? 0
    }

    public func apply(state: AppState) {
        pendingState = state
        scheduleFlush()
    }

    public func apply(mouseLocation: LogicalPoint) {
        pendingMouseLocation = mouseLocation
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: flushInterval, repeats: false) { [weak self] _ in
            self?.flush()
        }
        flushTimer = timer
        // .common: ウィンドウドラッグ等 (.eventTracking モード) の main run loop 中でもタイマーが
        // 発火するようにする。.default だけだとドラッグ中はタイマーが止まり、coalesce のつもりが
        // 「ドラッグ終了までまとめて 1 回」に化けて元の問題 (ドラッグ中に追従しない) が再発する。
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush() {
        flushTimer = nil
        if let s = pendingState {
            pendingState = nil
            applyStateImmediately(s)
        }
        if let loc = pendingMouseLocation {
            pendingMouseLocation = nil
            applyMouseLocationImmediately(loc)
        }
    }

    private func applyStateImmediately(_ state: AppState) {
        self.state = state
        // state 更新は mouseMoved 以外 (displayConfigurationChanged / calibration / settings) でも
        // 呼ばれるため、位置が実際に変わった時のみ activity として扱う。
        if let cur = state.currentMouse?.point {
            if cur != self.currentMouseLocation {
                self.currentMouseLocation = cur
                markActive()
            }
        }
        // DR-0009: state.focusFlash.generation が前回より進んでいれば新規発火として立ち上げる。
        // 同一 displayId でも generation が進めば再発火する (連続切替時の Cmd-Tab 連打・
        // 同一モニタ内アプリ切替を反映)。generation が変わらない state 更新
        // (displayConfigurationChanged 等) では何もしない。
        if let ff = state.focusFlash, ff.generation != lastFocusFlashGeneration {
            lastFocusFlashGeneration = ff.generation
            startFocusFlash(displayId: ff.displayId)
        }
    }

    private func applyMouseLocationImmediately(_ mouseLocation: LogicalPoint) {
        if mouseLocation != currentMouseLocation {
            currentMouseLocation = mouseLocation
            markActive()
        }
    }

    /// プレゼンテーションモード時のクリックイベントを適用する。
    /// - down: 現在の減衰タイマーを止めて initial opacity で表示開始
    /// - up: opacity を clickFadeDuration にわたって 0 まで減衰、完了で clickCircle=nil
    public func apply(presentationClick event: PresentationClickEvent) {
        clickFadeTimer?.invalidate()
        clickFadeTimer = nil
        switch event.phase {
        case .down:
            clickCircle = ClickCirclePresentation(point: event.point, opacity: clickInitialOpacity)
        case .up:
            guard let current = clickCircle else { return }
            // 減衰: 30ms 刻みで initial opacity / (clickFadeDuration / step) 分ずつ減らす。
            let step: TimeInterval = 0.03
            let ticks = max(1, Int(clickFadeDuration / step))
            let delta = current.opacity / Double(ticks)
            var opacity = current.opacity
            let point = current.point
            let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                opacity -= delta
                if opacity <= 0 {
                    self.clickCircle = nil
                    t.invalidate()
                    self.clickFadeTimer = nil
                } else {
                    self.clickCircle = ClickCirclePresentation(point: point, opacity: opacity)
                }
            }
            clickFadeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// プレゼンテーションモード off 遷移時に呼ぶ。減衰中でも即座にサークルを消す。
    public func clearPresentationClick() {
        clickFadeTimer?.invalidate()
        clickFadeTimer = nil
        clickCircle = nil
    }

    /// フォーカスフラッシュを立ち上げてフェードアウトさせる (DR-0009 Phase A)。
    /// state 経由の generation 変化検知から呼ばれる内部関数。
    ///
    /// 減衰は clickCircle 側と同じ pattern: 30ms 刻みで `focusFlashDuration / step` 回に分けて
    /// opacity を減らし、0 に達したら nil に戻す。SwiftUI の暗黙 animation ではなく AppKit Timer で
    /// 明示的に段階更新するのは、キャリブレーション画面表示中の main run loop 占有下でも
    /// 予測可能な速度で減衰させるため (プレゼンテーションクリックと同じ理由)。
    private func startFocusFlash(displayId: String) {
        focusFlashFadeTimer?.invalidate()
        focusFlashFadeTimer = nil
        focusFlash = FocusFlashPresentation(displayId: displayId, opacity: focusFlashInitialOpacity)

        let step: TimeInterval = 0.03
        let ticks = max(1, Int(focusFlashDuration / step))
        let delta = focusFlashInitialOpacity / Double(ticks)
        var opacity = focusFlashInitialOpacity
        let capturedId = displayId
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            opacity -= delta
            if opacity <= 0 {
                self.focusFlash = nil
                t.invalidate()
                self.focusFlashFadeTimer = nil
            } else {
                self.focusFlash = FocusFlashPresentation(displayId: capturedId, opacity: opacity)
            }
        }
        focusFlashFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// フォーカスフラッシュ機能 off 遷移時に呼ぶ。減衰中でも即座に消し、次回の generation 変化
    /// でも state.focusFlash?.generation との差分検知が正しく行われるよう lastFocusFlashGeneration
    /// は state の値に合わせておく (off 中の発火をカウントし、再 on 時に「見なかった 1 回」を
    /// 再生しないため = 「off の間の発火は捨てる」を明示する)。
    public func clearFocusFlash() {
        focusFlashFadeTimer?.invalidate()
        focusFlashFadeTimer = nil
        focusFlash = nil
        lastFocusFlashGeneration = state.focusFlash?.generation ?? 0
    }

    private func markActive() {
        isMouseActive = true
        inactivityWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isMouseActive = false
        }
        inactivityWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + inactivityThreshold, execute: item)
    }
}
