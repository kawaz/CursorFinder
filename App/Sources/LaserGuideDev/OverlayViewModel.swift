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

public final class OverlayViewModel: ObservableObject {
    @Published public var state: AppState
    @Published public var currentMouseLocation: LogicalPoint?
    /// #2 アイドルフェード: 直近 inactivityThreshold の間にマウス移動があったか。
    /// false の間、LaserOverlayView は描画をスキップする。
    @Published public var isMouseActive: Bool = false
    /// プレゼンテーションモード on 時のクリック可視化。off 時 / mouseUp 後の減衰完了時は nil。
    @Published public var clickCircle: ClickCirclePresentation?

    /// ポインタ移動停止からレーザーを消すまでの猶予 (v1 の Config.Timing.inactivityThreshold=0.3 と同値)。
    public var inactivityThreshold: TimeInterval = 0.3

    /// coalesce タイマーの周期 (60Hz = 約16.67ms)。テストで注入できるよう var にしておく。
    public var flushInterval: TimeInterval = 1.0 / 60.0

    /// mouseUp 後のクリックサークル消滅時間 (秒)。テスト用に注入可能。
    public var clickFadeDuration: TimeInterval = 0.3
    /// mouseDown 時のサークル初期不透明度。
    public var clickInitialOpacity: Double = 0.6

    private var inactivityWorkItem: DispatchWorkItem?
    private var pendingState: AppState?
    private var pendingMouseLocation: LogicalPoint?
    private var flushTimer: Timer?
    private var clickFadeTimer: Timer?

    public init(initialState: AppState, initialMouse: LogicalPoint? = nil) {
        self.state = initialState
        self.currentMouseLocation = initialMouse
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
