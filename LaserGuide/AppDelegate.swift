// AppDelegate.swift
import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var calibrationWindowController: NSWindowController?

    private let displayDetector = DisplayDetector.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 LaserGuide v2 started")

        // AppConfigurationを初期化（存在しない場合はデフォルト作成）
        let workspaceKey = displayDetector.workspace.configurationKey
        let _ = AppConfigurationManager.shared.loadOrCreateConfiguration(workspaceKey: workspaceKey)

        // ディスプレイ検出を開始
        displayDetector.startMonitoring()

        // メニューバーアイテムを作成
        setupMenuBar()

        NSLog("✅ LaserGuide v2 initialized")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("👋 LaserGuide v2 terminating")
        displayDetector.stopMonitoring()
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

    @objc private func copyDebugInfo() {
        ConfigurationManager.shared.copyDebugInfoToClipboard()
    }

    @objc private func reloadConfiguration() {
        displayDetector.reloadWorkspace()
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
