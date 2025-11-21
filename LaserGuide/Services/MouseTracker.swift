// MouseTracker.swift
import Cocoa
import Combine

/// マウス追跡サービス
class MouseTracker: ObservableObject {
    static let shared = MouseTracker()

    @Published private(set) var currentMouseLocation: CGPoint = .zero
    @Published private(set) var isMouseActive: Bool = false
    @Published private(set) var currentModifiers: NSEvent.ModifierFlags = []

    private var mouseMovedMonitor: Any?
    private var flagsChangedMonitor: Any?
    private var inactivityTimer: Timer?

    private init() {
    }

    /// 追跡を開始
    func startTracking() {
        guard mouseMovedMonitor == nil else {
            NSLog("⚠️ MouseTracker already started")
            return
        }

        NSLog("🖱️ MouseTracker started")

        // マウス移動イベント
        mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            guard let self = self else { return }

            // マウス位置を更新
            self.currentMouseLocation = NSEvent.mouseLocation

            // アクティブ状態にする
            if !self.isMouseActive {
                self.isMouseActive = true
            }

            // 非アクティブタイマーをリセット
            self.resetInactivityTimer()
        }

        // 修飾キー変更イベント
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self else { return }
            self.currentModifiers = event.modifierFlags
        }

        // 初期位置を取得
        currentMouseLocation = NSEvent.mouseLocation
        isMouseActive = true
        resetInactivityTimer()
    }

    /// 追跡を停止
    func stopTracking() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }

        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }

        inactivityTimer?.invalidate()
        inactivityTimer = nil

        NSLog("🖱️ MouseTracker stopped")
    }

    /// 強制Block状態かチェック
    var shouldForceBlock: Bool {
        guard let appConfig = AppConfigurationManager.shared.loadConfiguration() else {
            return false
        }
        guard appConfig.edgeNavigation.forceBlockEnabled else { return false }
        return appConfig.edgeNavigation.forceBlockModifiers.matches(currentModifiers)
    }

    /// 非アクティブタイマーをリセット
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()

        // AppConfigurationから閾値を取得
        let threshold: TimeInterval
        if let appConfig = AppConfigurationManager.shared.loadConfiguration() {
            threshold = appConfig.laser.inactivityThreshold
        } else {
            threshold = 0.3  // デフォルト
        }

        inactivityTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isMouseActive = false
            NSLog("💤 Mouse inactive")
        }
    }

    deinit {
        stopTracking()
    }
}
