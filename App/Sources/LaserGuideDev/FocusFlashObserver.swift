// FocusFlashObserver (DR-0011 / DR-0013): NSWorkspace + AX 経路でフォーカス変更を購読し、
// 所属モニタ id とフォーカスウィンドウ frame (震源) を解決して AppRuntime に
// `.focusedWindowChanged(displayId:windowFrame:)` を dispatch する入力アダプタ。
//
// 経路:
//   - NSWorkspace.didActivateApplicationNotification でアプリ切替を検知 (プロセス粒度)
//   - アクティブ pid に対し AXObserver で以下 3 通知列を購読 (DR-0013 決定 2、
//     `observedAXNotifications` の定数列で管理):
//       * kAXFocusedWindowChangedNotification (同一アプリ内のウィンドウ切替)
//       * kAXMainWindowChangedNotification    (main window 変更のみで focused が動かないパターン)
//       * kAXWindowCreatedNotification        (新規ダイアログ / シート / ドキュメントウィンドウ)
//     3 通知いずれも共通 handler (`handleFocusedWindowChanged`) に流れる。**kAXFocusedUIElementChanged
//     は購読しない** (テキストフィールド間フォーカスで大量発火、UX ノイズが実害を上回る、DR-0013)
//   - フォーカス中ウィンドウ frame は AX API (kAXFocusedWindowAttribute → kAXPositionAttribute
//     / kAXSizeAttribute) で取得
//   - AX 権限は EventTapController と同じアクセシビリティ権限で追加要求なし
//     (DR-0009 決定 4)。権限なし時は本アダプタを起動しない (AppDelegate 側で判定)
//
// 座標系 (DR-0005):
//   AX の kAXPositionAttribute は CG グローバル論理 (top-left y-down) を返す
//   ことが実機観測 (2026-07-12: 14 アプリ × CGWindowList 突合で全一致) で確定。
//   境界変換は identity として `convertAXFrameToCGGlobal` に 1 箇所集約 (DR-0005 規律)。
//
// 権限なし / AX 取得失敗時の degrade:
//   - PermissionMonitor.isTrusted が false ならこの observer は AppDelegate 側で起動しない
//   - AXObserverCreate 失敗 (AX 非対応アプリ等) は NSLog してアプリ切替のみで動作継続 (発火機会が
//     減るだけで壊れない)。AXUIElementCopyAttributeValue 失敗も同様、そのフォーカス切替を捨てる
//
// トグル off / deinit:
//   AppDelegate が `stop()` を呼ぶ → workspace observer 解除 + AXObserver 破棄 + RunLoop source 除去。
//   AXObserver は self を unretained で参照する (refcon)。stop() で完全に破棄してからでないと
//   self を解放しない契約 (deinit でも stop() を呼ぶ)。
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LaserGuideCore

/// フォーカス変更の解決結果 (テスト用に純関数として切り出せるよう struct 化)。
public struct FocusDisplayResolution: Equatable, Sendable {
    /// 解決された所属モニタ id (displays に含まれるものの中から選ばれる)
    public let displayId: String
    /// ウィンドウの中心点 (CG 論理座標)。ログ / 検証用の参考値。
    public let windowCenter: LogicalPoint
    public init(displayId: String, windowCenter: LogicalPoint) {
        self.displayId = displayId
        self.windowCenter = windowCenter
    }
}

/// AX から取ったウィンドウ frame と現在の displays 集合から所属モニタ id を解決する純関数。
/// テスト時は AX を経由せず直接呼べる。
///
/// - ウィンドウ frame の中心点が半開包含される display を優先
/// - どの display にも含まれない場合、中心点との距離が最小の display にフォールバック
///   (フルスクリーン化直後や複数モニタ境界跨ぎのウィンドウで空振りしないため)
/// - displays が空なら nil (発火しない)
public func resolveFocusDisplay(
    windowFrame: LogicalRect, displays: [Display]
) -> FocusDisplayResolution? {
    guard !displays.isEmpty else { return nil }
    let center = LogicalPoint(
        x: (windowFrame.minX + windowFrame.maxX) / 2,
        y: (windowFrame.minY + windowFrame.maxY) / 2
    )
    if let hit = displays.first(where: { $0.logicalBounds.containsHalfOpen(center) }) {
        return FocusDisplayResolution(displayId: hit.id, windowCenter: center)
    }
    // fallback: 中心点との L2 距離最小の display に寄せる
    var best: (Display, Double)?
    for d in displays {
        let cx = (d.logicalBounds.minX + d.logicalBounds.maxX) / 2
        let cy = (d.logicalBounds.minY + d.logicalBounds.maxY) / 2
        let dx = cx - center.x
        let dy = cy - center.y
        let sqr = dx * dx + dy * dy
        if let current = best {
            if sqr < current.1 { best = (d, sqr) }
        } else {
            best = (d, sqr)
        }
    }
    return best.map { FocusDisplayResolution(displayId: $0.0.id, windowCenter: center) }
}

/// window frame + displays から dispatch すべき Action を構築する純関数。
/// 解決不能 (displays が空 / resolveFocusDisplay が nil) の場合は nil。
/// unit test はここまでを対象とする (AX 経路は実機依存で unit test では覆えない)。
public func focusedWindowAction(
    windowFrame: LogicalRect, displays: [Display]
) -> Action? {
    guard let resolved = resolveFocusDisplay(windowFrame: windowFrame, displays: displays) else {
        return nil
    }
    return .focusedWindowChanged(displayId: resolved.displayId, windowFrame: windowFrame)
}

/// NSWorkspace 通知 + AXObserver でフォーカス変更を購読し、runtime に action を dispatch するアダプタ。
public final class FocusFlashObserver {

    /// installAXObserver / tearDownAXObserver で束ねて登録・解除する AX 通知の CFString 列 (DR-0013 決定 2)。
    /// 現状の 3 通知はいずれも共通 handler (`handleFocusedWindowChanged`) に流し、同一アプリ内の
    /// ウィンドウ / ダイアログ / 新規ウィンドウ生成でフォーカスフラッシュが発火する経路をここで一元管理する。
    /// 新規通知を追加するときはこの列に追記するだけで install / teardown 双方が自動的に走る。
    public static let observedAXNotifications: [CFString] = [
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString
    ]

    /// `observedAXNotifications` を順に `register` へ渡す純関数 (テスト可能な形の副作用注入)。
    /// 実行時 `installAXObserver` は `AXObserverAddNotification` を呼ぶ closure を渡し、テストは
    /// 「呼ばれた CFString 列」を記録する mock を渡して 3 通知が定数列通りに登録されることを固定する。
    public static func installAXNotifications(
        notifications: [CFString] = observedAXNotifications,
        register: (CFString) -> Void
    ) {
        for notif in notifications { register(notif) }
    }

    /// `observedAXNotifications` を順に `unregister` へ渡す純関数 (`installAXNotifications` と対称)。
    /// 実行時は `AXObserverRemoveNotification` を呼び、テストは呼ばれ列を記録する。
    public static func removeAXNotifications(
        notifications: [CFString] = observedAXNotifications,
        unregister: (CFString) -> Void
    ) {
        for notif in notifications { unregister(notif) }
    }

    private weak var runtime: AppRuntime?
    private var workspaceObserver: NSObjectProtocol?

    // AXObserver 状態 (アクティブアプリに追従して張り替える)
    private var axObserver: AXObserver?
    private var axApp: AXUIElement?
    private var axPid: pid_t?

    public init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    deinit {
        stop()
    }

    /// 購読開始。AppDelegate から AX 権限判定後に呼ぶ。
    /// 二重登録防止のため、まず既存があれば解除する (トグル on↔off 遷移時の安全性)。
    public func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.handleAppActivation(app)
        }
    }

    public func stop() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObserver = nil
        tearDownAXObserver()
    }

    // MARK: - internals

    private func handleAppActivation(_ app: NSRunningApplication) {
        NSLog("[LaserGuide focus] activated app=\(app.localizedName ?? "?") pid=\(app.processIdentifier)")
        // アプリ単位フォーカスに追従して即発火 (アプリ切替 = 通常はウィンドウ切替を伴う)。
        dispatchIfResolvable(pid: app.processIdentifier)
        // 続いて同一アプリ内のウィンドウ切替を捕捉するため AXObserver を張り替える。
        installAXObserver(pid: app.processIdentifier)
    }

    /// AXObserver コールバック本体。監視中の pid に対する focused window を取り直して dispatch。
    fileprivate func handleFocusedWindowChanged() {
        guard let pid = axPid else { return }
        dispatchIfResolvable(pid: pid)
    }

    private func dispatchIfResolvable(pid: pid_t) {
        guard let runtime else { return }
        guard let frame = focusedWindowFrame(for: pid) else {
            // AX 取得失敗: このフォーカス切替は捨てる。focusedWindowFrame 内で NSLog 済み。
            return
        }
        guard let action = focusedWindowAction(windowFrame: frame, displays: runtime.state.displays) else {
            NSLog("[LaserGuide focus] focusedWindowAction returned nil (displays empty?)")
            return
        }
        runtime.dispatch(action)
    }

    // MARK: - AXObserver 配線

    private func installAXObserver(pid: pid_t) {
        // 同一 pid への再インストールは skip (Cmd-Tab 往復のたびの張り直しを避ける)。
        if axPid == pid, axObserver != nil { return }
        tearDownAXObserver()
        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, focusFlashAXObserverCallback, &observer)
        guard createErr == .success, let obs = observer else {
            NSLog("[LaserGuide focus] AXObserverCreate failed: pid=\(pid) axError=\(createErr.rawValue)")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged<FocusFlashObserver>.passUnretained(self).toOpaque()
        // DR-0013: 3 通知を定数列 (`observedAXNotifications`) で一括登録。1 通知でも登録失敗した場合は
        // NSLog に残しつつ他の通知は登録を継続する (kAXWindowCreated が古い app で unsupported の場合等、
        // 他の通知だけでも動く方が価値がある — 全滅させない、DR-0013 の degrade 方針)。
        Self.installAXNotifications { notif in
            let err = AXObserverAddNotification(obs, app, notif, refcon)
            if err != .success {
                NSLog("[LaserGuide focus] AXObserverAddNotification failed: pid=\(pid) notif=\(notif) axError=\(err.rawValue)")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        self.axObserver = obs
        self.axApp = app
        self.axPid = pid
    }

    private func tearDownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            if let app = axApp {
                Self.removeAXNotifications { notif in
                    AXObserverRemoveNotification(obs, app, notif)
                }
            }
        }
        axObserver = nil
        axApp = nil
        axPid = nil
    }

    /// AX でフォーカス中ウィンドウの frame を取る。戻り値は CG グローバル論理 (top-left y-down)。
    private func focusedWindowFrame(for procId: pid_t) -> LogicalRect? {
        let axApp = AXUIElementCreateApplication(procId)
        var focused: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused)
        guard posErr == .success, let focusedRef = focused else {
            // 対象アプリが AX 非対応 / システム UI 等で kAXFocusedWindowAttribute が取れないケースを
            // Console.app から切り分けできるよう AXError code を出力する。
            NSLog("[LaserGuide focus] kAXFocusedWindowAttribute failed: pid=\(procId) axError=\(posErr.rawValue)")
            return nil
        }
        // AXUIElement は CoreFoundation 型 (CFTypeID が AXUIElementGetTypeID と一致) なので
        // force cast で AXUIElement に落とす。AX API 契約上 kAXFocusedWindowAttribute の
        // 値は必ず AXUIElement を返すため、この cast は AX API 契約が破られない限り安全。
        // swiftlint:disable:next force_cast
        let axWindow = focusedRef as! AXUIElement

        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
        let r2 = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)
        guard r1 == .success, r2 == .success,
              let posV = posValue, let sizeV = sizeValue else {
            NSLog("""
                [LaserGuide focus] position/size attribute failed: pid=\(procId) \
                axErrorPosition=\(r1.rawValue) axErrorSize=\(r2.rawValue)
                """)
            return nil
        }

        var cgPos = CGPoint.zero
        var cgSize = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(posV as! AXValue, .cgPoint, &cgPos)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeV as! AXValue, .cgSize, &cgSize)

        return convertAXFrameToCGGlobal(position: cgPos, size: cgSize)
    }

    /// AX 由来の (position, size) を CG グローバル LogicalRect (top-left y-down) に変換する境界関数。
    /// 実機観測 (2026-07-12) で AX kAXPositionAttribute は既に CG グローバル y-down を返すため
    /// identity 変換。DR-0005 の「境界変換は 1 箇所」規律に則り関数として独立させておく。
    private func convertAXFrameToCGGlobal(position: CGPoint, size: CGSize) -> LogicalRect {
        LogicalRect(
            minX: Double(position.x),
            minY: Double(position.y),
            maxX: Double(position.x + size.width),
            maxY: Double(position.y + size.height)
        )
    }
}

// MARK: - AXObserver C callback

/// AXObserver から呼ばれる C コールバック。refcon には passUnretained した
/// FocusFlashObserver ポインタが入る。RunLoop source を main に張っているので main で呼ばれる。
private func focusFlashAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let target = Unmanaged<FocusFlashObserver>.fromOpaque(refcon).takeUnretainedValue()
    target.handleFocusedWindowChanged()
}
