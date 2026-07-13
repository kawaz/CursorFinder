// AppDelegate — 全体の配線 (runtime, tap, overlays, screen change, status bar)
//
// SwiftLint 抑止 (file 単位、DR-0010 スコープ内):
//   - file_length / type_body_length: AppDelegate は App の起動 orchestration を担う
//     配線層で、tap / overlay / persistence / menu / focus flash / calibration の各
//     サブシステムを stateful に紐づける単一責務クラス。分割は「起動順序に依存する
//     配線を複数箇所に分散させる」副作用があり、Phase 1 の単一責務が明確なうちは
//     まとまっている方が可読性が高い。Phase 2 で個別コーディネータへの切り出しを検討。
// swiftlint:disable file_length
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
import Combine
import Foundation
import LaserGuideCore

// swiftlint:disable:next type_body_length
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, EffectInterpreter {

    /// `applicationDidFinishLaunching` で必ず生成される。他のライフサイクルメソッドは
    /// 起動完了後にしか AppKit から呼ばれないため、この IUO は「クラス invariant を
    /// 起動タイミング制約で保証する」正当な使い方。SPM executable の main.swift 経路
    /// でも同様に applicationDidFinishLaunching 前に他のプロパティアクセスは無い。
    private var runtime: AppRuntime! // swiftlint:disable:this implicitly_unwrapped_optional
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
    private var focusFlashToggleItem: NSMenuItem?
    private var latencyInfoItem: NSMenuItem?
    /// プレゼンテーションモード on 時のみ有効な mouseDown/Up 監視 (VM への Action 配送用)。
    private var presentationClickMonitor: Any?
    /// on の間だけ生きるフォーカス変更購読 (AX + NSWorkspace)。off 時 / 権限失効時は nil。
    private var focusFlashObserver: FocusFlashObserver?

    /// DR-0012: 表示チューニング + 機能トグルの単一情報源。UserDefaults から起動時にロード、
    /// 変更のたびに全 OverlayViewModel と機能配線に live apply する。
    private let settingsStore = SettingsStore()
    /// $settings 購読ハンドル (deinit / applicationWillTerminate まで生きる)。
    private var settingsCancellable: AnyCancellable?
    /// 直前に適用した settings (差分検知用 — トグルの副作用を毎回叩かないため)。
    private var lastAppliedSettings: DisplaySettings?

    /// DR-0012: 設定ウィンドウ (SwiftUI TabView)。キャリブレーションもタブの 1 つとして embed。
    private var settingsWindow: SettingsWindowController?

    // 機能トグルは settingsStore.settings のミラー。既存コード互換のため計算プロパティで公開。
    private var warpEnabled: Bool { settingsStore.settings.warpEnabled }
    private var presentationModeEnabled: Bool { settingsStore.settings.presentationModeEnabled }
    private var focusFlashEnabled: Bool { settingsStore.settings.focusFlashEnabled }

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
                """
                [LaserGuide] persistence loaded: displays=\(reconciled.displays.count) \
                userSegments=\(reconciled.userSegments.count) \
                inactive=\(reconciled.inactiveUserSegments.count) \
                didMigrateFromV1=\(boot.didMigrateFromV1) \
                temporaryKeysDeleted=\(boot.temporaryKeysDeleted.count)
                """
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
            // DR-0012: 設定ウィンドウのキャリブレーションタブが開いているときは RenderModel を
            // 追加で push (bridge 側で 60Hz coalesce)。閉じているときは no-op。
            self?.settingsWindow?.applyCalibrationState(state)
        }

        setupOverlays(for: scan)
        setupStatusItem()
        // DR-0012: SettingsStore の live apply を購読。@Published の `projected publisher` は
        // sink 登録時に必ず現在値を replay するため (Combine 仕様)、明示的な初回 applySettings 呼び出しは
        // 不要 (レビュー m-6 の修正 — 旧コメントの「念のため」は誤解。二重適用を避け、sink に一任する)。
        settingsCancellable = settingsStore.$settings.sink { [weak self] settings in
            self?.applySettings(settings)
        }

        // 権限判定 → tap or fallback。DR-0004: 権限なしはワープのみ停止、レーザー描画は継続。
        //
        // C-2 / m-1: 永続化された warp OFF を尊重する — 起動時 `settings.warpEnabled == false` なら
        // `ctrl.start()` はスキップし、self.tap への保持だけ行う。以降のトグル ON 遷移は
        // applySettings 経由の setWarpEnabled(true) で ctrl.start() が呼ばれる (差分検知は
        // applySettingsCore が担うので、tap ライフサイクルの判断は一箇所に集約される)。drag position
        // monitor も warp OFF 時は起動しない (warp OFF 時は tap 経由の位置更新が無い前提の既存挙動と整合)。
        if PermissionMonitor.isTrusted(prompt: true) {
            let ctrl = EventTapController(runtime: runtime)
            self.tap = ctrl
            if settingsStore.settings.warpEnabled {
                if !ctrl.start() {
                    // tapCreate が失敗した場合は fallback へ倒す (実行中に権限が剥がれるケースの雛形)
                    self.tap = nil
                    startLaserOnlyFallback()
                } else {
                    // #5: tap から除外したドラッグ系イベントでも overlay がカーソルを追えるよう、
                    //   位置更新だけを別経路 (NSEvent global monitor) で拾う。warp は発火しない。
                    startDragPositionMonitor()
                }
            }
            // warp OFF 起動時: tap 生成のみ、start しない。以降 applySettings が warp ON 遷移を
            // 検知した時点で ctrl.start() が呼ばれる (setWarpEnabled 副作用)。
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
        focusFlashObserver?.stop()
        focusFlashObserver = nil
    }

    // MARK: - Drag position monitor (#5)

    /// tap eventsOfInterest から除外したドラッグ系イベントの位置更新だけを購読する。
    /// NSEvent.mouseLocation は y-up (bottom-left) なので primary NSScreen 高さで CG y-down に変換。
    ///
    /// ドラッグ移動も mouseMoved と同格の「ポインタ活動」として常に VM へ流す — レーザーが
    /// アイドルフェードで消えた後でも、ボタンを押したまま動かせばレーザーが復活する
    /// (2026-07-10 実機第 3 ラウンド: 旧実装は isMouseActive == false の間ドラッグを丸ごと
    /// 捨てていたため、mousedown で静止 → フェード → そのまま動かしても再描画されなかった)。
    /// パフォーマンスはここで間引かず OverlayViewModel 側の coalesce (トレーリングエッジ
    /// スロットル) に一元化する — この closure の仕事は CG 変換と pending 値の上書きだけで、
    /// @Published 発火 (SwiftUI 再評価) はイベントレートに比例しない。
    private func startDragPositionMonitor() {
        stopDragPositionMonitor()
        dragPositionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
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
        // M-1: 新規 VM は defaults 初期値のままなので、SettingsStore の表示チューニング (色 / 太さ /
        // タイミング / 波動パラメータ) と機能副作用 (プレゼンテーションモード) を再適用する。
        // 旧実装は applyPresentationMode() のみで、色や太さのカスタムが rebuild でデフォルトに巻き戻る
        // バグがあった。
        let settings = settingsStore.settings
        for (_, vm) in overlayModelById {
            settings.applyDisplayParameters(to: vm)
        }
        applyPresentationMode(settings)
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

    /// 2026-07-10 実機フィードバック第 2 ラウンド #3: 起動時に権限が無かった場合、tap は
    /// 永久に nil のままだった (再起動しないと有効化されない)。メニューを開くたびに呼び、
    /// 権限が後から付与されていれば applicationDidFinishLaunching の権限あり分岐と同じ配線
    /// (tap 生成 → laser-only fallback 停止 → drag position monitor 起動) をその場で行う。
    /// 既に tap があるか、まだ権限が無ければ何もしない (冪等)。
    ///
    /// m-1: warp OFF 時は tap の生成 (self.tap 保持) までは行うが `ctrl.start()` はスキップする —
    /// 起動時分岐と同じ判断軸 (C-2)。以降のトグル ON で applySettings の setWarpEnabled(true) が
    /// ctrl.start() を呼ぶ経路に合流する。
    private func ensureTapIfTrusted() {
        guard tap == nil else { return }
        guard PermissionMonitor.isTrusted(prompt: false) else { return }
        let ctrl = EventTapController(runtime: runtime)
        tap = ctrl
        permission.stopLaserOnly()
        if settingsStore.settings.warpEnabled {
            if !ctrl.start() {
                tap = nil
                return
            }
            startDragPositionMonitor()
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
        // フォーカスフラッシュ (DR-0009 Phase A): アプリ切替時にフォーカス先モニタの縁を短時間
        // ハイライト。既定 off (実機フィードバック待ち)。AX 権限なし時は disabled 表示。
        let focusFlashToggle = NSMenuItem(
            title: "フォーカスフラッシュ", action: #selector(toggleFocusFlash),
            keyEquivalent: "")
        focusFlashToggle.target = self
        focusFlashToggle.state = focusFlashEnabled ? .on : .off
        // 権限なしなら disabled + 状態は off 固定 (Phase A の degrade)。
        if !PermissionMonitor.isTrusted(prompt: false) {
            focusFlashToggle.isEnabled = false
            focusFlashToggle.toolTip = "アクセシビリティ権限が必要です"
        }
        menu.addItem(focusFlashToggle)
        self.focusFlashToggleItem = focusFlashToggle
        menu.addItem(.separator())
        // DR-0012: 設定ウィンドウ (⌘,)。SettingsStore と機能トグル + 表示チューニングを触れる。
        let settingsItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        // DR-0008: キャリブレーション画面を開く (設定ウィンドウのキャリブレーションタブを開くショートカット)。
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

    /// DR-0012: メニューからのトグルは SettingsStore に書き戻し、購読ハンドラ (applySettings)
    /// 経由で機能配線 + メニュー state 更新を一元化する。旧実装のようにここで sender.state を
    /// 直接触ると、設定ウィンドウ側の Toggle と食い違う (双方向同期の主線を SettingsStore に置く)。
    @objc private func toggleWarp(_ sender: NSMenuItem) {
        settingsStore.settings.warpEnabled.toggle()
    }

    @objc private func togglePresentationMode(_ sender: NSMenuItem) {
        settingsStore.settings.presentationModeEnabled.toggle()
    }

    @objc private func toggleFocusFlash(_ sender: NSMenuItem) {
        settingsStore.settings.focusFlashEnabled.toggle()
    }

    /// DR-0012: 「設定...」メニュー項目からの遷移。単一インスタンスの settings window を前面化。
    @objc private func openSettings() {
        openSettingsWindow(initialTab: .general)
    }

    private func openSettingsWindow(initialTab: SettingsTab) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: settingsStore, runtime: runtime)
        }
        settingsWindow?.show(initialTab: initialTab)
    }

    /// DR-0012 live apply: SettingsStore 変化を受けて全 VM の該当 var + 機能配線に反映する。
    /// 差分検知と副作用は `applySettingsCore` にテスト可能な形で切り出しており (レビュー m-5)、
    /// AppDelegate はここで実副作用 (tap / observer / menu / VM) を注入する薄い adapter に留まる。
    private func applySettings(_ settings: DisplaySettings) {
        let previous = lastAppliedSettings
        lastAppliedSettings = settings
        applySettingsCore(previous: previous, current: settings, effects: makeSideEffects())
    }

    /// AppDelegate の実副作用を SettingsSideEffects にパッケージ化して返す。テストからは
    /// `applySettingsCore` を直接呼び、mock effects を渡して分岐 (C-1 の新値受け取り / C-2 の
    /// 初回適用 / M-1 の rebuild 再適用のトリガ) を検証する。
    private func makeSideEffects() -> SettingsSideEffects {
        SettingsSideEffects(
            setWarpEnabled: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    // 権限あり + tap 保持済み前提。tap 未生成 (権限なし) 時は fallback が担うので no-op。
                    _ = self.tap?.start()
                    self.startDragPositionMonitor()
                } else {
                    self.tap?.stop()
                    self.stopDragPositionMonitor()
                }
            },
            applyPresentationMode: { [weak self] settings in
                self?.applyPresentationMode(settings)
            },
            applyFocusFlash: { [weak self] settings in
                self?.applyFocusFlash(settings)
            },
            updateMenuStates: { [weak self] settings in
                self?.warpToggleItem?.state = settings.warpEnabled ? .on : .off
                self?.presentationToggleItem?.state = settings.presentationModeEnabled ? .on : .off
                self?.focusFlashToggleItem?.state = settings.focusFlashEnabled ? .on : .off
            },
            applyDisplayParametersToAllViewModels: { [weak self] settings in
                guard let self else { return }
                for (_, vm) in self.overlayModelById {
                    settings.applyDisplayParameters(to: vm)
                }
            })
    }

    /// focusFlashEnabled (引数の `settings` から読む、C-1 対応) を反映する: observer 起動/停止 +
    /// 減衰中の描画クリア。**旧実装は computed mirror (`self.focusFlashEnabled`) を読んでいた**が、
    /// Combine の @Published は willSet で sink に emit するため sink 内から computed を読むと
    /// 旧値を返し、トグルが 1 周遅れになる (C-1 の根本原因)。settings を引数で明示的に受け取ることで
    /// stale read を構造的に排除する。
    private func applyFocusFlash(_ settings: DisplaySettings) {
        if settings.focusFlashEnabled {
            // 権限有無に関わらず起動を試みる (menu で権限なし時は disabled になっているが、
            // 実行中の権限剥奪等の遷移で通ってしまうケースに備える)。
            guard focusFlashObserver == nil else { return }
            let observer = FocusFlashObserver(runtime: runtime)
            observer.start()
            focusFlashObserver = observer
        } else {
            focusFlashObserver?.stop()
            focusFlashObserver = nil
            for (_, vm) in overlayModelById { vm.clearFocusFlash() }
        }
    }

    /// presentationModeEnabled (引数の `settings` から読む、C-1 対応) を全 overlay に反映する:
    /// sharingType 切替 + click 監視の起動/停止。overlay の再構築 (rebuildOverlays) からも呼ぶことで
    /// 新規モニタでも設定が継続する — 呼び出し側 (rebuildOverlays / applySettingsCore) が現在の
    /// settings を必ず渡すことで、旧 computed mirror 経路の stale read を排除。
    private func applyPresentationMode(_ settings: DisplaySettings) {
        let type: NSWindow.SharingType = settings.presentationModeEnabled ? .readOnly : .none
        for ctrl in overlays {
            ctrl.window.sharingType = type
        }
        if settings.presentationModeEnabled {
            startPresentationClickMonitor()
        } else {
            stopPresentationClickMonitor()
            for (_, vm) in overlayModelById { vm.clearPresentationClick() }
        }
    }

    /// プレゼンテーションモード on 時の click 監視。NSEvent.mouseLocation は y-up bottom-left
    /// なので PermissionMonitor.nsScreenPointToCG で CG y-down に変換して VM に配送する。
    ///
    /// 2026-07-10 実機フィードバック第 2 ラウンド #2: down/up に加え dragged 系も購読し、
    /// ボタンを押している間サークルがカーソルに追従するようにする。mouseMoved (ボタンを
    /// 押していない移動) はここでは購読しない — 座標追跡は既存の drag position monitor が
    /// 別経路で担い、責務は変えない。
    ///
    /// パフォーマンス: dragged は OS のイベントレポートレートに比例した高頻度で飛んでくる。
    /// drag position monitor (#5) と同じパターンで、サークルが表示されていない (= up 後、
    /// down を経ていないドラッグ) 場合は CG 変換と全 VM 走査を行わずに早期 return する。
    private func startPresentationClickMonitor() {
        stopPresentationClickMonitor()
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let upMask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        let dragMask: NSEvent.EventTypeMask = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        presentationClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [downMask, upMask, dragMask].reduce(NSEvent.EventTypeMask()) { $0.union($1) }
        ) { [weak self] event in
            guard let self else { return }
            let phase: PresentationClickEvent.Phase
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: phase = .down
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: phase = .up
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                guard self.overlayModelById.values.contains(where: { $0.clickCircle != nil }) else { return }
                phase = .drag
            default: return
            }
            let cg = PermissionMonitor.nsScreenPointToCG(NSEvent.mouseLocation)
            let point = LogicalPoint(x: Double(cg.x), y: Double(cg.y))
            let action = PresentationClickEvent(phase: phase, point: point)
            for (_, vm) in self.overlayModelById { vm.apply(presentationClick: action) }
        }
    }

    private func stopPresentationClickMonitor() {
        if let m = presentationClickMonitor { NSEvent.removeMonitor(m) }
        presentationClickMonitor = nil
    }

    /// 2026-07-10 実機フィードバック第 2 ラウンド #4: tap が nil (権限なし/未有効化) の場合と
    /// tap は生きているがサンプルがまだ 0 件の場合を区別する (interface-wording: エラーは
    /// 原因+対処)。前者は「権限を付与してメニューを開き直す」という具体的な対処を示す。
    @objc private func copyLatency() {
        let text: String
        if let tap {
            text = tap.latency.summary()?.oneLineDescription
                ?? "no latency samples yet (move the mouse first)"
        } else {
            text = "event tap inactive (アクセシビリティ権限を付与後、メニューを開き直してください)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// DR-0012: 独立ウィンドウは廃止し、設定ウィンドウのキャリブレーションタブへ遷移するショートカット。
    @objc private func openCalibration() {
        openSettingsWindow(initialTab: .calibration)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // #3: 権限が起動後に付与されたケースに追従する (tap 再生成を試みてから表示を作る)。
        ensureTapIfTrusted()
        // #4: tap nil (権限なし) と tap ありサンプル 0 件を区別した表示。
        if let tap {
            if let summary = tap.latency.summary() {
                latencyInfoItem?.title = "tap レイテンシ: \(summary.oneLineDescription)"
            } else {
                latencyInfoItem?.title = "tap レイテンシ: 計測待ち (マウスを動かして)"
            }
        } else {
            latencyInfoItem?.title = "tap レイテンシ: event tap 無効 (アクセシビリティ権限を確認してください)"
        }
        // #3: focusFlash トグルは権限付与後にメニューを開き直せば有効化される。
        let trusted = PermissionMonitor.isTrusted(prompt: false)
        focusFlashToggleItem?.isEnabled = trusted
        focusFlashToggleItem?.toolTip = trusted ? nil : "アクセシビリティ権限が必要です"
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
