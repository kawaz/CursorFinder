// AutoLaunchManager.swift
import Foundation
import ServiceManagement

/// 自動起動の管理を担当するクラス
class AutoLaunchManager {
    static let shared = AutoLaunchManager()

    private let autoLaunchKey = "autoLaunchEnabled"

    private init() {}

    /// 自動起動が有効かどうか
    var isEnabled: Bool {
        get {
            // SMAppServiceの状態を確認
            SMAppService.mainApp.status == .enabled
        }
        set {
            if newValue {
                enable()
            } else {
                disable()
            }
        }
    }

    /// 自動起動を有効化
    @discardableResult
    func enable() -> Bool {
        do {
            if SMAppService.mainApp.status == .enabled {
                return true
            }
            try SMAppService.mainApp.register()
            NSLog("LaserGuide: Auto-launch enabled")
            return true
        } catch {
            NSLog("LaserGuide: Failed to enable auto-launch: \(error)")
            return false
        }
    }

    /// 自動起動を無効化
    @discardableResult
    func disable() -> Bool {
        do {
            if SMAppService.mainApp.status == .notRegistered {
                return true
            }
            try SMAppService.mainApp.unregister()
            NSLog("LaserGuide: Auto-launch disabled")
            return true
        } catch {
            NSLog("LaserGuide: Failed to disable auto-launch: \(error)")
            return false
        }
    }

    /// 自動起動のトグル
    @discardableResult
    func toggle() -> Bool {
        isEnabled = !isEnabled
        return isEnabled
    }
}
