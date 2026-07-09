// OverlayViewModel (DR-0004: 描画は state 購読、individual action を舐めない)
//
// AppRuntime.stateDidChange と、権限 fallback 時の NSEvent monitor からの mouse 位置更新を
// 1 か所にまとめ、SwiftUI ObservableObject として overlay に流す。
//
// 現在マウス位置の source of truth:
//   - 権限あり (通常経路): AppRuntime.state.currentMouse (Store が更新する)
//   - 権限なし (fallback): NSEvent global monitor (permission fallback 起動時のみ購読)
// どちらも同じ CG y-down 論理座標として `currentMouseLocation` に反映される。
import Foundation
import AppKit
import Combine
import LaserGuideCore

public final class OverlayViewModel: ObservableObject {
    @Published public var state: AppState
    @Published public var currentMouseLocation: LogicalPoint?

    public init(initialState: AppState, initialMouse: LogicalPoint? = nil) {
        self.state = initialState
        self.currentMouseLocation = initialMouse
    }

    public func apply(state: AppState) {
        self.state = state
        if let cur = state.currentMouse?.point {
            self.currentMouseLocation = cur
        }
    }

    public func apply(mouseLocation: LogicalPoint) {
        self.currentMouseLocation = mouseLocation
    }
}
