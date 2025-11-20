// AppDelegate.swift
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var screenManager = ScreenManager.shared
    private var calibrationWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 多重起動の防止
        if isAnotherInstanceRunning() {
            NSLog("LaserGuide: Another instance is already running. Terminating.")
            NSApp.terminate(nil)
            return
        }

        setupStatusBar()
        screenManager.setupOverlays()
        
        // グローバルマウス追跡を開始
        MouseTrackingManager.shared.startTracking()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "🔍"

            // マウス追跡への干渉を最小化するためのイベント処理設定
            button.sendAction(on: [.leftMouseUp])
        }

        let menu = NSMenu()

        // About項目
        let aboutItem = NSMenuItem(
            title: "About LaserGuide...",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // キャリブレーション設定項目
        let calibrateItem = NSMenuItem(
            title: "Calibrate Physical Layout...",
            action: #selector(openCalibration),
            keyEquivalent: ""
        )
        calibrateItem.target = self
        menu.addItem(calibrateItem)

        menu.addItem(NSMenuItem.separator())

        // 自動起動の設定項目
        let autoLaunchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleAutoLaunch),
            keyEquivalent: ""
        )
        autoLaunchItem.target = self
        autoLaunchItem.state = AutoLaunchManager.shared.isEnabled ? .on : .off
        menu.addItem(autoLaunchItem)

        menu.addItem(NSMenuItem.separator())

        // 物理レイアウト使用設定項目
        let usePhysicalLayoutItem = NSMenuItem(
            title: "Use Physical Layout",
            action: #selector(toggleUsePhysicalLayout),
            keyEquivalent: ""
        )
        usePhysicalLayoutItem.target = self
        let isEnabled = UserDefaults.standard.object(forKey: "UsePhysicalLayout") as? Bool ?? true
        usePhysicalLayoutItem.state = isEnabled ? .on : .off
        menu.addItem(usePhysicalLayoutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func openAbout() {
        // Close existing window if any
        aboutWindow?.close()
        aboutWindow = nil

        // Create new about window
        let contentView = AboutView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About LaserGuide"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        // Activate the app to bring window to front
        NSApp.activate(ignoringOtherApps: true)

        aboutWindow = window
    }

    @objc private func openCalibration() {
        // Close existing window if any
        calibrationWindow?.close()
        calibrationWindow = nil

        // Create new calibration window
        let contentView = CalibrationView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Physical Display Layout Calibration"
        window.contentViewController = hostingController
        window.center()
        // window.level = .floating  // Removed: Allow window to be covered by other windows
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        // Activate the app to bring window to front
        NSApp.activate(ignoringOtherApps: true)

        calibrationWindow = window
    }

    @objc private func toggleAutoLaunch(_ sender: NSMenuItem) {
        let newState = AutoLaunchManager.shared.toggle()
        sender.state = newState ? .on : .off
    }

    @objc private func toggleUsePhysicalLayout(_ sender: NSMenuItem) {
        let newState = sender.state == .off
        sender.state = newState ? .on : .off

        UserDefaults.standard.set(newState, forKey: "UsePhysicalLayout")
        NotificationCenter.default.post(
            name: .usePhysicalLayoutDidChange,
            object: newState
        )

        NSLog("🔧 Use Physical Layout toggled: \(newState ? "ON" : "OFF")")
    }

    @objc private func screensDidChange() {
        screenManager.setupOverlays()
    }

    @objc private func quitApp() {
        // アプリ終了時にマウス追跡を停止
        MouseTrackingManager.shared.stopTracking()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Duplicate Launch Prevention

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let instances = runningApps.filter { $0.bundleIdentifier == bundleIdentifier }

        // 自分自身を含めて2つ以上のインスタンスがある場合は多重起動
        return instances.count > 1
    }
}
