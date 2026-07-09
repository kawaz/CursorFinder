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

public final class OverlayViewModel: ObservableObject {
    @Published public var state: AppState
    @Published public var currentMouseLocation: LogicalPoint?
    /// #2 アイドルフェード: 直近 inactivityThreshold の間にマウス移動があったか。
    /// false の間、LaserOverlayView は描画をスキップする。
    @Published public var isMouseActive: Bool = false

    /// ポインタ移動停止からレーザーを消すまでの猶予 (v1 の Config.Timing.inactivityThreshold=0.3 と同値)。
    public var inactivityThreshold: TimeInterval = 0.3

    /// coalesce タイマーの周期 (60Hz = 約16.67ms)。テストで注入できるよう var にしておく。
    public var flushInterval: TimeInterval = 1.0 / 60.0

    private var inactivityWorkItem: DispatchWorkItem?
    private var pendingState: AppState?
    private var pendingMouseLocation: LogicalPoint?
    private var flushTimer: Timer?

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
