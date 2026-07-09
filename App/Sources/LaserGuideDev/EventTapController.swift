// EventTapController (DR-0004: tap callback 内での同期 dispatch + event.location 書き換え)
//
// - .cghidEventTap + mouseMoved を main run loop に載せる (排他制御なし)
// - callback で AppRuntime.dispatchForTap(.mouseMoved) を呼び、返る rewriteEventLocation を
//   その場で event.location に書き換えて返す (同期性契約、DR-0004)
// - tapDisabledByTimeout / tapDisabledByUserInput は eventTapDisabled action として dispatch し、
//   interpreter が reenableTap effect で CGEvent.tapEnable を呼び直す
//
// 2026-07-10 実機フィードバック #5:
//   - eventsOfInterest を **mouseMoved のみ**に絞る。leftMouseDragged / rightMouseDragged /
//     otherMouseDragged は tap 経路から除外し、window ドラッグを OS 側へ素通しさせる
//     (ドラッグ中のワープは元々ユーザ体験として望ましくない上、tap callback にドラッグ
//     イベント列を流し込むと reduce + SwiftUI 更新のキュー滞留が「止めても行き過ぎる」
//     症状の原因になっていた)
//   - callback の reduce 所要時間を LatencyTracker で計測 (DR-0004 の p50/p99 実装)
//   - レーザー描画に必要なドラッグ中のポインタ位置は AppDelegate 側の NSEvent global
//     monitor で拾う (別経路、warp は発火しない)
import CoreGraphics
import Foundation
import LaserGuideCore

public final class EventTapController {

    private weak var runtime: AppRuntime?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastLocation: CGPoint?

    public let latency = LatencyTracker()

    public init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    /// tap を作成して main run loop に登録する。成功時 true。
    /// アクセシビリティ権限が無ければ tapCreate が nil を返し false を返す。
    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else { return true }
        // #5: mouseMoved のみ。ドラッグ系は OS へ素通し。
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let ctrl = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
                return ctrl.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = src
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// interpreter からの reenableTap effect を反映する経路。
    public func reenable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // ================================
    // callback
    // ================================

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            runtime?.dispatch(.eventTapDisabled(reason: .timeout))
            return nil
        case .tapDisabledByUserInput:
            runtime?.dispatch(.eventTapDisabled(reason: .userInput))
            return nil
        default:
            break
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let loc = event.location
        let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        let sign = DeltaSign(dx: signum(deltaX), dy: signum(deltaY))

        // event が絶対座標のみを提供する経路 (画面をまたぐジャンプ等) の delta 補完:
        // getIntegerValueField(.mouseEventDeltaX/Y) が 0 の時、直前位置との差分で符号を推定する。
        // DR-0006「符号のみ契約」なので大きさは使わない。
        var sign2 = sign
        if sign.dx == 0 && sign.dy == 0, let prev = lastLocation {
            sign2 = DeltaSign(dx: signum(Int(loc.x - prev.x)), dy: signum(Int(loc.y - prev.y)))
        }
        lastLocation = loc

        let logical = LogicalPoint(x: Double(loc.x), y: Double(loc.y))
        let rewrite = runtime?.dispatchForTap(.mouseMoved(location: logical, deltaSign: sign2))
        if let p = rewrite {
            event.location = CGPoint(x: p.x, y: p.y)
            lastLocation = event.location
        }
        let end = DispatchTime.now().uptimeNanoseconds
        latency.record(nanoseconds: end &- start)
        return Unmanaged.passUnretained(event)
    }

    private func signum(_ v: Int64) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }
    private func signum(_ v: Int) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }
}
