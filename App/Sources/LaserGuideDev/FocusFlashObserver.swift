// FocusFlashObserver (DR-0009 Phase A): NSWorkspace + AX 経路でフォーカス先モニタを解決し、
// AppRuntime に `.focusedDisplayChanged(displayId:)` を dispatch する入力アダプタ。
//
// 経路の選定 (2026-07-10):
//   - NSWorkspace.didActivateApplicationNotification でアプリ切替を検知
//   - フォーカス中のウィンドウ frame は AX API (kAXFocusedWindowAttribute → kAXPositionAttribute
//     / kAXSizeAttribute) で取得。frame は Phase A では所属モニタ id 解決にのみ使用し、
//     ウィンドウ枠のアウトライン描画は Phase B へ持ち越し
//   - AX 権限は EventTapController と同じアクセシビリティ権限で追加要求なし
//     (DR-0009 決定 4)。権限なし時は本アダプタを起動しない (AppDelegate 側で判定)
//
// AX/CGWindowList 選定理由: DR-0009 決定 2/3/4 が AX 経路を仕様レベルで前提としており、
// Phase B (window frame outline) でも AX が必要になるため経路統一で AX を選ぶ。CGWindowList は
// system UI (menubar/dock/screencapture) を弾く owningPID フィルタが必要になり、Phase A 単独の
// 実装コストとしては同等以下だが Phase A→B の連続性で不利。
//
// 座標系の扱い (DR-0005 / DR-0009 決定 3):
//   AX の kAXPositionAttribute は macOS 上の実測で **global screen coordinates, top-left y-down**
//   (= CGDisplayBounds と同じ CG グローバル論理座標) を返す。CGDisplayBounds に含まれる矩形との
//   合致で display id を解決できる (座標変換不要)。
//   DR-0009 決定 3 は「AX y-up → CG y-down 変換を入力アダプタで行う」と書いてあるが、実機観測
//   (Cocoa 系 AX 実装) では既に y-down なので変換不要。DR-0005 の「境界 (入力アダプタ層) で
//   即 CG 変換」規律は満たされる (identity 変換として実装)。実機フィードバックで y 反転バグが
//   確認された場合は本ファイルの `convertToCGGlobal` を y-flip 実装に差し替える。DR-0009 決定 3
//   の「y-up 前提」と実機観測のズレは Phase A 実機確認後に DR 側を訂正する候補 (journal / DR-0009
//   の追記案件)。
//
// 権限なし / AX 取得失敗時の degrade:
//   - PermissionMonitor.isTrusted が false ならこの observer は AppDelegate 側で起動しない
//   - AXUIElementCopyAttributeValue が失敗 (対象アプリが AX 非対応 / システム UI 等) した場合、
//     Phase A では発火しない (今回のフォーカス切替を捨てる)。ユーザには menubar / Finder 等の
//     アプリ切替が flash を伴わないケースとして観測されうる — 実機確認事項
//
// トグル off 遷移時:
//   AppDelegate が `stop()` を呼ぶ → observer 解除 + VM.clearFocusFlash() でフェード中の描画も
//   即座に消える
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LaserGuideCore

/// フォーカス変更の解決結果 (テスト用に純関数として切り出せるよう struct 化)。
public struct FocusDisplayResolution: Equatable, Sendable {
    /// 解決された所属モニタ id (displays に含まれるものの中から選ばれる)
    public let displayId: String
    /// ウィンドウの中心点 (CG 論理座標)。Phase B 拡張時にログや DR 検証で使う参考値。
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

/// NSWorkspace 通知 + AX 経路でフォーカス変更を購読し、runtime に action を dispatch するアダプタ。
public final class FocusFlashObserver {

    private weak var runtime: AppRuntime?
    private var workspaceObserver: NSObjectProtocol?

    public init(runtime: AppRuntime) {
        self.runtime = runtime
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
    }

    // MARK: - internals

    private func handleAppActivation(_ app: NSRunningApplication) {
        NSLog("[LaserGuide focus] activated app=\(app.localizedName ?? "?") pid=\(app.processIdentifier)")
        guard let runtime else { return }
        guard let frame = focusedWindowFrame(for: app.processIdentifier) else {
            // AX 取得失敗: このフォーカス切替は捨てる (Phase A で degrade を明示)。
            // 2026-07-10 #3: silent-fail のままだと実機で切り分けできないため、
            // focusedWindowFrame 内の各 guard で NSLog 済み (AXError code 込み)。
            return
        }
        guard let resolved = resolveFocusDisplay(windowFrame: frame, displays: runtime.state.displays) else {
            NSLog("[LaserGuide focus] resolveFocusDisplay returned nil (displays empty?)")
            return
        }
        runtime.dispatch(.focusedDisplayChanged(displayId: resolved.displayId))
    }

    /// AX でフォーカス中ウィンドウの frame を取る。Phase A ではこの frame は displayId 解決にのみ使用。
    /// 戻り値の座標系は CG グローバル論理 (top-left y-down)。
    private func focusedWindowFrame(for procId: pid_t) -> LogicalRect? {
        let axApp = AXUIElementCreateApplication(procId)
        var focused: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused)
        guard posErr == .success, let focusedRef = focused else {
            // 2026-07-10 #3: silent-fail 診断。対象アプリが AX 非対応 / システム UI 等で
            // kAXFocusedWindowAttribute が取れないケースを実機の Console.app から切り分け
            // できるよう AXError code を出力する。
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

        let frame = convertAXFrameToCGGlobal(position: cgPos, size: cgSize)
        return frame
    }

    /// AX 由来の (position, size) を CG グローバル LogicalRect (top-left y-down) に変換する境界関数。
    ///
    /// 実装ノート (DR-0005 / DR-0009 決定 3):
    ///   Cocoa/AppKit ベースのアプリでは AX kAXPositionAttribute は既に CG グローバル (top-left
    ///   y-down) を返すため identity 変換で足りる (実機観測)。DR-0009 決定 3 は「AX y-up」と
    ///   記述しているが、これは AX が伝統的に Cocoa 座標系 (y-up) を扱うという一般論に基づく
    ///   もので、実機挙動とは乖離している可能性が高い。Phase A の実機確認で y 反転バグが観測
    ///   された場合は本関数を y-flip 実装に差し替え、DR-0009 決定 3 の注記を訂正する。
    ///
    ///   本関数を独立させておくことで、実機確認結果に応じた差し替えは 1 箇所で済む (DR-0005
    ///   「境界変換を 1 か所に集約」規律)。
    private func convertAXFrameToCGGlobal(position: CGPoint, size: CGSize) -> LogicalRect {
        // identity 変換 (現時点で最も妥当な仮説):
        LogicalRect(
            minX: Double(position.x),
            minY: Double(position.y),
            maxX: Double(position.x + size.width),
            maxY: Double(position.y + size.height)
        )
    }
}
