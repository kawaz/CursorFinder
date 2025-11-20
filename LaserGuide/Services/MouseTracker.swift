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
    private let settings: AppSettings
    
    private let inactivityThreshold: TimeInterval
    
    private init() {
        self.settings = AppSettingsManager.shared.loadSettings()
        self.inactivityThreshold = settings.inactivityThreshold
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
        guard settings.forceBlockEnabled else { return false }
        return settings.forceBlockModifiers.matches(currentModifiers)
    }
    
    /// 非アクティブタイマーをリセット
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()
        
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isMouseActive = false
            NSLog("💤 Mouse inactive")
        }
    }
    
    deinit {
        stopTracking()
    }
}

