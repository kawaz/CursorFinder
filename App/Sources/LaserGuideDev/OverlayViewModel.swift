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

    private var inactivityWorkItem: DispatchWorkItem?

    public init(initialState: AppState, initialMouse: LogicalPoint? = nil) {
        self.state = initialState
        self.currentMouseLocation = initialMouse
    }

    public func apply(state: AppState) {
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

    public func apply(mouseLocation: LogicalPoint) {
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
