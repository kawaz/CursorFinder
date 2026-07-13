// SettingsWindowController (DR-0012)
//
// 設定ウィンドウの生成・表示・閉じ処理と、キャリブレーションブリッジのライフサイクル管理。
// 単一インスタンス (再表示は同じウィンドウを前面化)、リサイズ可、初期サイズはキャリブレーション
// タブが実用になる 1000x640。
//
// LSUIElement=true (accessory app、ドック無し) での前面化は既存の
// activate → makeKeyAndOrderFront → orderFrontRegardless の 3 段パターンを踏襲する
// (旧 CalibrationWindowController.show と同じ挙動)。
import AppKit
import LaserGuideCore
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let store: SettingsStore
    private let runtime: AppRuntime
    private var window: NSWindow?
    /// CalibrationTabView から参照される bridge。設定ウィンドウを開いている間だけ生きる。
    /// AppDelegate は `applyCalibrationState(_:)` 経由で state を流す。
    private(set) var calibration: CalibrationBridge?

    init(store: SettingsStore, runtime: AppRuntime) {
        self.store = store
        self.runtime = runtime
    }

    /// 設定ウィンドウを開く (単一インスタンス)。
    ///
    /// - **初回**: 新規に NSWindow + SettingsView を組み立てて、`initialTab` (未指定なら `.general`)
    ///   を初期選択タブにする。
    /// - **既に開いている場合**: 前面化のみ行い、`initialTab` は無視する (レビュー m-4:
    ///   ユーザが別タブで作業中に「設定...」再選択で強制的に一般タブへ飛ばされないため)。
    ///   キャリブレーションタブへ明示遷移したい呼び出し側は、閉じてから再度 show するか、
    ///   将来の拡張で `selectTabNotification` 経路を通す。
    func show(initialTab: SettingsTab? = nil) {
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            return
        }
        let bridge = CalibrationBridge(runtime: runtime)
        self.calibration = bridge

        let contentRect = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        win.title = "LaserGuide 設定"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 1000, height: 640)
        win.center()

        let root = SettingsView(
            store: store,
            calibrationView: CalibrationTabView(bridge: bridge),
            initialTab: initialTab ?? .general)
        let hosting = NSHostingController(rootView: root)
        win.contentViewController = hosting
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()

        // WebView 読み込み後にも requestInitialRender で state が push されるが、
        // 開いた瞬間に現在の state を配線しておく (旧独立ウィンドウの挙動と同等)。
        bridge.apply(state: runtime.state)
    }

    /// AppDelegate から state 変化のたびに呼ばれる。ウィンドウが開いている間だけ WebView に反映。
    func applyCalibrationState(_ state: AppState) {
        calibration?.apply(state: state)
    }

    /// 手動で閉じる用 (メニュー/テスト等)。NSWindow の close を呼ぶと windowWillClose が呼ばれ、
    /// bridge の teardown + 参照解放が実行される。
    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        calibration?.teardown()
        calibration = nil
        window = nil
    }

    // MARK: - Tab selection (open 済みで別タブに切り替えたい時のシグナル)

    /// SettingsView が購読して current tab を切り替える通知。show(initialTab:) 経路では open 済み時に
    /// 発火しない (m-4 の裁定)。将来「特定操作から強制的に別タブへ」のような機能を追加する場合の
    /// 拡張口として残す。
    static let selectTabNotification = Notification.Name("LaserGuide.SettingsWindow.selectTab")
}
