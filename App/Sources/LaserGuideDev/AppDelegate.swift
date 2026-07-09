// AppDelegate — 全体の配線 (runtime, tap, overlays, screen change, status bar)
//
// フロー:
//   1. DisplaySnapshotProvider.scan() → 初期 AppState (Display + 初期 pose)
//   2. AppRuntime を作り、権限があれば EventTapController.start()。
//      無ければ PermissionMonitor.startLaserOnly() でレーザーのみ mode
//   3. 各ディスプレイに OverlayWindowController を作って show()
//   4. NSApplication.didChangeScreenParametersNotification を購読、
//      DisplaySnapshotProvider を再スキャンして .displayConfigurationChanged を dispatch、
//      overlay を作り直す
//   5. status item に Quit のみを載せる (Phase 1)
import AppKit
import Foundation
import LaserGuideCore

final class AppDelegate: NSObject, NSApplicationDelegate, EffectInterpreter {

    private var runtime: AppRuntime!
    private var tap: EventTapController?
    private let permission = PermissionMonitor()

    private var overlays: [OverlayWindowController] = []
    private var overlayModelById: [String: OverlayViewModel] = [:]

    private var statusItem: NSStatusItem?
    private var warpEnabled: Bool = true

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 起動時 scan + 初期 pose を state に注入。既存 pose が無い初回は Store.reduce の
        // displayConfigurationChanged では identity になるので、AppState を初期化する時点で
        // pose 込みで作る。
        let scan = DisplaySnapshotProvider.scan()
        let displays = scan.snapshots.map { snap -> Display in
            let pose = scan.initialPoses[snap.id] ?? .identity
            return Display(id: snap.id, logicalBounds: snap.logicalBounds, pose: pose)
        }
        let initial = AppState(displays: displays, userSegments: [])
        runtime = AppRuntime(initial: initial)
        runtime.setInterpreter(self)
        runtime.stateDidChange = { [weak self] state in
            self?.dispatchStateToOverlays(state)
        }

        setupOverlays(for: scan)
        setupStatusItem()

        // 権限判定 → tap or fallback。DR-0004: 権限なしはワープのみ停止、レーザー描画は継続。
        if PermissionMonitor.isTrusted(prompt: true) {
            let ctrl = EventTapController(runtime: runtime)
            if !ctrl.start() {
                // tapCreate が失敗した場合は fallback へ倒す (実行中に権限が剥がれるケースの雛形)
                startLaserOnlyFallback()
            } else {
                self.tap = ctrl
            }
        } else {
            startLaserOnlyFallback()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap?.stop()
        permission.stopLaserOnly()
    }

    // MARK: - Screen change

    @objc private func screenParametersChanged() {
        let scan = DisplaySnapshotProvider.scan()
        // 既知 pose を既存 state から引き継ぎ、未知は初期 pose を注入するため
        // displayConfigurationChanged action と、その後に必要なら pose 補完で対応する。
        runtime.dispatch(.displayConfigurationChanged(scan.snapshots))
        // 新規モニタには state の identity pose が入っているので、scan.initialPoses で置き換える
        // (直接 state を触るのは runtime API の外だが Phase 1 の便宜として実装。Phase 2 で
        // displayConfigurationChanged に pose を運ぶ経路を検討する — 報告に列挙)。
        overrideNewDisplayPoses(with: scan)
        rebuildOverlays(for: scan)
    }

    /// scan の initialPoses のうち、state.displays に identity で入ってしまっているモニタだけ
    /// pose を差し替える。Store の reduce は「既知 id は従来 pose を引き継ぎ、新規は identity」の
    /// 契約 (AppState.swift のコメント) なので、この補完は runtime 層の責務。
    private func overrideNewDisplayPoses(with scan: DisplayScanResult) {
        var state = runtime.state
        var changed = false
        let newDisplays = state.displays.map { d -> Display in
            if d.pose == .identity, let p = scan.initialPoses[d.id], p != .identity {
                changed = true
                return Display(id: d.id, logicalBounds: d.logicalBounds, pose: p)
            }
            return d
        }
        if changed {
            // reduce を通さず state を差し替えるのは DR-0004 の Elm 系列を崩すが、pose 補完は
            // displayConfigurationChanged と論理的に不可分な副作用のため Phase 1 は許容 (Phase 2
            // で pose を lifted した action / effect にする、報告に列挙)。
            state.displays = newDisplays
            // state.tables は displays に依存する derived state なので、再度同 action を通す
            // ことで整合させる (簡易対応)。
            runtime.dispatch(.displayConfigurationChanged(state.displays.map {
                DisplaySnapshot(id: $0.id, logicalBounds: $0.logicalBounds)
            }))
        }
    }

    // MARK: - Overlays

    private func setupOverlays(for scan: DisplayScanResult) {
        overlays.forEach { $0.hide() }
        overlays.removeAll()
        overlayModelById.removeAll()

        let state = runtime.state
        for snap in scan.snapshots {
            guard let cgId = scan.cgDisplayIdOf[snap.id] else { continue }
            let vm = OverlayViewModel(initialState: state)
            if let ctrl = OverlayWindowController(displayId: snap.id, cgDisplayId: cgId, model: vm) {
                overlays.append(ctrl)
                overlayModelById[snap.id] = vm
                ctrl.show()
            }
        }
    }

    private func rebuildOverlays(for scan: DisplayScanResult) {
        // 既存 window を閉じて作り直す (Phase 1、削減余地あり)
        setupOverlays(for: scan)
    }

    private func dispatchStateToOverlays(_ state: AppState) {
        for (_, vm) in overlayModelById { vm.apply(state: state) }
    }

    private func startLaserOnlyFallback() {
        permission.startLaserOnly { [weak self] p in
            guard let self else { return }
            for (_, vm) in self.overlayModelById { vm.apply(mouseLocation: p) }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LG"
        let menu = NSMenu()
        let warpToggle = NSMenuItem(title: "Warp: on", action: #selector(toggleWarp), keyEquivalent: "w")
        warpToggle.target = self
        menu.addItem(warpToggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LaserGuide (dev)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleWarp(_ sender: NSMenuItem) {
        warpEnabled.toggle()
        sender.title = warpEnabled ? "Warp: on" : "Warp: off"
        if warpEnabled {
            _ = tap?.start()
        } else {
            tap?.stop()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - EffectInterpreter

    func handlePersist(_ workspace: PersistedWorkspace) {
        // Phase 1: 永続化は未実装 (UserDefaults 経路の骨組みは Phase 2)。ログのみ。
        NSLog("[LaserGuide] persist: userSegments=\(workspace.userSegments.count) configuration=\(workspace.configuration)")
    }

    func handleReenableTap() {
        tap?.reenable()
    }

    func handleNotifyPermissionLost() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限が失効しました"
        alert.informativeText = "システム設定 > プライバシーとセキュリティ > アクセシビリティ で LaserGuide-dev を許可してください。レーザー描画のみで動作を継続します。"
        alert.alertStyle = .warning
        alert.runModal()
        tap?.stop()
        startLaserOnlyFallback()
    }
}
