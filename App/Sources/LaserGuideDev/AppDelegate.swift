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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, EffectInterpreter {

    private var runtime: AppRuntime!
    private var tap: EventTapController?
    private let permission = PermissionMonitor()
    /// 2026-07-10 フィードバック #5 対応: tap から除外したドラッグ系イベントでもレーザーが
    /// カーソルを追えるよう、位置更新だけを NSEvent global monitor で拾う (warp は発火しない)。
    private var dragPositionMonitor: Any?

    private var overlays: [OverlayWindowController] = []
    private var overlayModelById: [String: OverlayViewModel] = [:]

    private var statusItem: NSStatusItem?
    private var warpToggleItem: NSMenuItem?
    private var presentationToggleItem: NSMenuItem?
    private var latencyInfoItem: NSMenuItem?
    private var warpEnabled: Bool = true
    /// プレゼンテーションモード (issue 2026-07-10-presentation-mode-capture-toggle):
    /// on のとき overlay window の sharingType を .readOnly にしてキャプチャに映るようにし、
    /// NSEvent global monitor で mouseDown/Up を購読してクリック可視化サークルを描画する。
    private var presentationModeEnabled: Bool = false
    /// プレゼンテーションモード on 時のみ有効な mouseDown/Up 監視 (VM への Action 配送用)。
    private var presentationClickMonitor: Any?

    /// DR-0008: WKWebView キャリブレーション UI。メニューから開いたときに生成、閉じたら再生成。
    private var calibration: CalibrationWindowController?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 起動時 scan + 初期 pose を state に注入。既存 pose が無い初回は Store.reduce の
        // displayConfigurationChanged では identity になるので、AppState を初期化する時点で
        // pose 込みで作る。
        let scan = DisplaySnapshotProvider.scan()
        // DR-0007 永続化配線: v3 → v1 → none の順で試す。scale は現構成の値で上書きし、
        // translate は保存値を尊重する (DR-0005 決定 2、DR-0007 決定 1 に基づく team-lead 指示)。
        let boot = PersistenceBoot.loadAndPersist(
            store: UserDefaults.standard,
            currentSnapshots: scan.snapshots,
            currentScaleByHardwareId: buildCurrentScaleMap(scan: scan),
            currentPixelSizeByHardwareId: buildCurrentPixelSizeMap(scan: scan))
        let initial: AppState
        switch boot.outcome {
        case let .usedPersisted(reconciled):
            NSLog(
                "[LaserGuide] persistence loaded: displays=\(reconciled.displays.count) userSegments=\(reconciled.userSegments.count) inactive=\(reconciled.inactiveUserSegments.count) didMigrateFromV1=\(boot.didMigrateFromV1) temporaryKeysDeleted=\(boot.temporaryKeysDeleted.count)"
            )
            initial = AppState(
                displays: reconciled.displays,
                userSegments: reconciled.userSegments,
                inactiveUserSegments: reconciled.inactiveUserSegments)
        case .noPersistence:
            NSLog("[LaserGuide] persistence: none found, initializing from OS defaults")
            let displays = scan.snapshots.map { snap -> Display in
                let pose = scan.initialPoses[snap.id] ?? .identity
                return Display(id: snap.id, logicalBounds: snap.logicalBounds, pose: pose)
            }
            // DR-0006 決定 5: 永続設定がまだ無い新規構成なので、userSegments は osPassSegments の
            // コピーで初期化する (= userSegments: [] だと全継ぎ目が PB になり OS のネイティブ通過を
            // 能動的にブロックしてしまう。2026-07-10 実機フィードバック #4 の確定原因)。
            initial = AppState.initial(displays: displays)
        }
        runtime = AppRuntime(initial: initial)
        runtime.setInterpreter(self)
        runtime.stateDidChange = { [weak self] state in
            self?.dispatchStateToOverlays(state)
            // DR-0008: キャリブレーション UI を開いているときは RenderModel を追加で push。
            // CalibrationWindowController 側で 60Hz coalesce するので毎 action で呼んで良い。
            self?.calibration?.apply(state: state)
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
                // #5: tap から除外したドラッグ系イベントでも overlay がカーソルを追えるよう、
                //   位置更新だけを別経路 (NSEvent global monitor) で拾う。warp は発火しない。
                startDragPositionMonitor()
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
        stopDragPositionMonitor()
        stopPresentationClickMonitor()
    }

    // MARK: - Drag position monitor (#5)

    /// tap eventsOfInterest から除外したドラッグ系イベントの位置更新だけを購読する。
    /// NSEvent.mouseLocation は y-up (bottom-left) なので main NSScreen 高さで CG y-down に変換。
    ///
    /// 2026-07-10 第 2 ラウンド #5: レーザーが非表示 (アイドルフェード後、isMouseActive == false)
    /// の間は追跡そのものをスキップする。目的は「既に見えているレーザーがドラッグ中も座標に
    /// 追従し続け、ドラッグ終了時に古い位置へジャンプしないこと」であり、非表示中に始まった
    /// ドラッグ (= ウィンドウ移動等、レーザーと無関係な操作である可能性が高い) まで毎イベント
    /// CG 変換 + overlay 走査を行う必要はない。OverlayViewModel 側の 60Hz coalesce と合わせて
    /// 二重にコストを削る。
    private func startDragPositionMonitor() {
        stopDragPositionMonitor()
        dragPositionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            guard self.overlayModelById.values.contains(where: { $0.isMouseActive }) else { return }
            let cg = PermissionMonitor.nsScreenPointToCG(NSEvent.mouseLocation)
            let p = LogicalPoint(x: Double(cg.x), y: Double(cg.y))
            for (_, vm) in self.overlayModelById { vm.apply(mouseLocation: p) }
        }
    }

    private func stopDragPositionMonitor() {
        if let m = dragPositionMonitor { NSEvent.removeMonitor(m) }
        dragPositionMonitor = nil
    }

    // MARK: - Persistence helpers

    /// DR-0007 の V1Migration.migrate に渡す px サイズ辞書 (v3 hardwareId をキーに)。
    /// logicalBounds は CG y-down px なので幅・高さがそのまま px 数になる。
    private func buildCurrentPixelSizeMap(scan: DisplayScanResult) -> [String: V1CurrentPixelSize] {
        Dictionary(uniqueKeysWithValues: scan.snapshots.map { snap in
            (snap.id, V1CurrentPixelSize(
                width: snap.logicalBounds.maxX - snap.logicalBounds.minX,
                height: snap.logicalBounds.maxY - snap.logicalBounds.minY))
        })
    }

    /// scan の initialPoses から scaleX/scaleY 辞書を作る (mm/px)。保存 pose の scale を
    /// この値で上書きするために PersistenceBoot に渡す (DR-0005 決定 2)。
    private func buildCurrentScaleMap(scan: DisplayScanResult) -> [String: (scaleX: Double, scaleY: Double)] {
        var out: [String: (scaleX: Double, scaleY: Double)] = [:]
        for (id, pose) in scan.initialPoses {
            out[id] = (pose.scaleX, pose.scaleY)
        }
        return out
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
        // 新規 overlay にプレゼンテーションモード設定を再適用 (sharingType + click monitor)
        applyPresentationMode()
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
        menu.delegate = self
        // 境界ワープのトグル: レーザー描画とは独立の機能なので、on/off はチェックマーク
        // (macOS 標準のトグル表現) で示す。レーザーは常時描画。
        let warpToggle = NSMenuItem(title: "境界ワープ", action: #selector(toggleWarp), keyEquivalent: "w")
        warpToggle.target = self
        warpToggle.state = warpEnabled ? .on : .off
        menu.addItem(warpToggle)
        self.warpToggleItem = warpToggle
        // プレゼンテーションモード (キャプチャ表示 + クリック可視化) のトグル。既定は off
        // (通常はキャプチャ除外 = v1 由来の完成品設定を尊重)。on にすると sharingType=.readOnly、
        // mouseDown/Up を購読してサークルを描画。
        let presentationToggle = NSMenuItem(
            title: "プレゼンテーションモード", action: #selector(togglePresentationMode),
            keyEquivalent: "")
        presentationToggle.target = self
        presentationToggle.state = presentationModeEnabled ? .on : .off
        menu.addItem(presentationToggle)
        self.presentationToggleItem = presentationToggle
        menu.addItem(.separator())
        // DR-0008: キャリブレーション画面を開く
        let calibItem = NSMenuItem(title: "キャリブレーション...", action: #selector(openCalibration), keyEquivalent: "k")
        calibItem.target = self
        menu.addItem(calibItem)
        menu.addItem(.separator())
        // tap レイテンシ統計: メニューを開くたびに menuWillOpen で最新値へ更新する表示専用行。
        let latencyInfo = NSMenuItem(title: "tap レイテンシ: 計測待ち (マウスを動かして)", action: nil, keyEquivalent: "")
        latencyInfo.isEnabled = false
        menu.addItem(latencyInfo)
        self.latencyInfoItem = latencyInfo
        let latencyCopy = NSMenuItem(title: "レイテンシ統計をコピー", action: #selector(copyLatency), keyEquivalent: "l")
        latencyCopy.target = self
        menu.addItem(latencyCopy)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LaserGuide (dev)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleWarp(_ sender: NSMenuItem) {
        warpEnabled.toggle()
        sender.state = warpEnabled ? .on : .off
        if warpEnabled {
            _ = tap?.start()
        } else {
            tap?.stop()
        }
    }

    @objc private func togglePresentationMode(_ sender: NSMenuItem) {
        presentationModeEnabled.toggle()
        sender.state = presentationModeEnabled ? .on : .off
        applyPresentationMode()
    }

    /// presentationModeEnabled の値を全 overlay に反映する: sharingType 切替 + click 監視の
    /// 起動/停止。overlay の再構築 (rebuildOverlays) からも呼ぶことで、新規モニタでも設定が
    /// 継続する。
    private func applyPresentationMode() {
        let type: NSWindow.SharingType = presentationModeEnabled ? .readOnly : .none
        for ctrl in overlays {
            ctrl.window.sharingType = type
        }
        if presentationModeEnabled {
            startPresentationClickMonitor()
        } else {
            stopPresentationClickMonitor()
            for (_, vm) in overlayModelById { vm.clearPresentationClick() }
        }
    }

    /// プレゼンテーションモード on 時の click 監視。NSEvent.mouseLocation は y-up bottom-left
    /// なので PermissionMonitor.nsScreenPointToCG で CG y-down に変換して VM に配送する。
    /// mouseMoved / dragged はここでは購読しない (座標追跡は drag position monitor が既に担う)。
    private func startPresentationClickMonitor() {
        stopPresentationClickMonitor()
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let upMask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        presentationClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [downMask, upMask].reduce(NSEvent.EventTypeMask()) { $0.union($1) }
        ) { [weak self] event in
            guard let self else { return }
            let cg = PermissionMonitor.nsScreenPointToCG(NSEvent.mouseLocation)
            let point = LogicalPoint(x: Double(cg.x), y: Double(cg.y))
            let phase: PresentationClickEvent.Phase
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: phase = .down
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: phase = .up
            default: return
            }
            let action = PresentationClickEvent(phase: phase, point: point)
            for (_, vm) in self.overlayModelById { vm.apply(presentationClick: action) }
        }
    }

    private func stopPresentationClickMonitor() {
        if let m = presentationClickMonitor { NSEvent.removeMonitor(m) }
        presentationClickMonitor = nil
    }

    @objc private func copyLatency() {
        let text = tap?.latency.summary()?.oneLineDescription
            ?? "no latency samples yet (move the mouse first)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openCalibration() {
        if calibration == nil {
            calibration = CalibrationWindowController(runtime: runtime)
        }
        calibration?.show()
        // 初回表示時に現在の state で JS 側の boot を助ける (WebView 読み込み完了後の
        // requestInitialRender でも同じ経路が走るが、こちらは冗長性のため)。
        calibration?.apply(state: runtime.state)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if let summary = tap?.latency.summary() {
            latencyInfoItem?.title = "tap レイテンシ: \(summary.oneLineDescription)"
        } else {
            latencyInfoItem?.title = "tap レイテンシ: 計測待ち (マウスを動かして)"
        }
    }

    // MARK: - EffectInterpreter

    func handlePersist(_ workspace: PersistedWorkspaceV3) {
        // DR-0007 決定 2: v3 key へ書き込む。encode に失敗した場合は log のみ (プロセスが持つ
        // state は残るので次回機会に再書き込みされる)。
        PersistenceBoot.persist(workspace, to: UserDefaults.standard)
        let segCount = workspace.displays.reduce(0) { $0 + $1.userSegments.count }
        NSLog("[LaserGuide] persist v\(workspace.version): displays=\(workspace.displays.count) userSegments(total)=\(segCount)")
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
