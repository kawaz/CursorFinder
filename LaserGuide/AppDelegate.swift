// AppDelegate.swift
import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var laserWindowControllers: [NSWindowController] = []
    private var calibrationWindowController: NSWindowController?

    private let displayDetector = DisplayDetector.shared
    private let mouseTracker = MouseTracker.shared
    private let edgeCrossingDetector = EdgeCrossingDetector.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 LaserGuide v2 started")

        // AppConfigurationを初期化（存在しない場合はデフォルト作成）
        let workspaceKey = displayDetector.workspace.configurationKey
        let _ = AppConfigurationManager.shared.loadOrCreateConfiguration(workspaceKey: workspaceKey)

        // サービスを開始
        displayDetector.startMonitoring()
        mouseTracker.startTracking()
        edgeCrossingDetector.startMonitoring()

        // レーザーウィンドウを作成
        setupLaserWindows()

        // メニューバーアイテムを作成
        setupMenuBar()

        // ディスプレイ変更を監視
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisplayConfigurationChanged),
            name: Notification.Name("LaserGuide.DisplayConfigurationChanged"),
            object: nil
        )

        NSLog("✅ LaserGuide v2 initialized")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("👋 LaserGuide v2 terminating")

        displayDetector.stopMonitoring()
        mouseTracker.stopTracking()
        edgeCrossingDetector.stopMonitoring()

        // レーザーウィンドウを閉じる
        laserWindowControllers.forEach { $0.close() }
        laserWindowControllers.removeAll()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            NSLog("❌ ステータスバーボタンの作成に失敗")
            return
        }

        button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "LaserGuide")

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "LaserGuide v2", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "物理配置キャリブレーション...", action: #selector(openCalibration), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "デバッグ情報をコピー", action: #selector(copyDebugInfo), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "設定をリロード", action: #selector(reloadConfiguration), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func setupLaserWindows() {
        // 既存のウィンドウを閉じる
        laserWindowControllers.forEach { $0.close() }
        laserWindowControllers.removeAll()

        let workspace = displayDetector.workspace

        NSLog("🖼️ \(workspace.displays.count)個のレーザーウィンドウを作成")

        // 各ディスプレイにレーザーウィンドウを作成
        for display in workspace.displays {
            let window = createLaserWindow(for: display)
            let controller = NSWindowController(window: window)
            controller.showWindow(nil)
            laserWindowControllers.append(controller)
        }
    }

    private func createLaserWindow(for display: Display) -> NSWindow {
        let logicalFrame = display.coordinates.logical
        let frame = CGRect(
            x: logicalFrame.position.x,
            y: logicalFrame.position.y,
            width: logicalFrame.size.width,
            height: logicalFrame.size.height
        )

        // 対応するNSScreenを検索
        let screen = NSScreen.screens.first(where: {
            let fingerprint = DisplayFingerprint(screen: $0)
            return fingerprint.stringRepresentation == display.hardware.fingerprint
        }) ?? NSScreen.main

        // フルスクリーンの透明ウィンドウ
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver  // 最前面
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true  // マウスイベントを透過
        window.hasShadow = false

        // レーザービューを設定（TODO: Phase 7で実装）
        let hostingView = NSHostingView(rootView: LaserView(display: display))
        window.contentView = hostingView

        return window
    }

    @objc private func handleDisplayConfigurationChanged() {
        NSLog("🔄 ディスプレイ設定が変更されました。ウィンドウを再作成します")
        setupLaserWindows()
    }

    @objc private func copyDebugInfo() {
        ConfigurationManager.shared.copyDebugInfoToClipboard()
    }

    @objc private func reloadConfiguration() {
        displayDetector.reloadWorkspace()
        setupLaserWindows()
        NSLog("🔄 設定をリロードしました")
    }

    @objc private func openCalibration() {
        // 既存のウィンドウがあれば前面に
        if let existingWindow = calibrationWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 新しいウィンドウを作成
        let calibrationView = PhysicalLayoutView()
        let hostingController = NSHostingController(rootView: calibrationView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "物理配置キャリブレーション"
        window.contentViewController = hostingController
        window.center()

        calibrationWindowController = NSWindowController(window: window)
        calibrationWindowController?.showWindow(nil)

        NSApp.activate(ignoringOtherApps: true)
        NSLog("📐 キャリブレーションウィンドウを開きました")
    }
}
