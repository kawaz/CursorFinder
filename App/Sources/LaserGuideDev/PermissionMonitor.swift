// PermissionMonitor (DR-0004: 権限失効時はワープのみ停止、レーザー描画は NSEvent monitor で継続)
//
// - 起動時: AXIsProcessTrustedWithOptions で権限有無を判定 (prompt=true で初回はダイアログ)
// - 権限なし: EventTapController は起動せず、NSEvent.addGlobalMonitorForEvents(.mouseMoved)
//   でマウス位置だけ購読し overlay に流す (レーザーのみ mode)
// - 権限あり: 通常経路。CGEventTap が働く
//
// 「実行中に権限を剥奪された」検知は tapCreate 成功後の tapDisabled callback 経由でしか観測
// しにくいため、Phase 1 は起動時判定のみ。実行中失効の完全検知は Phase 2 の課題 (findings に記録)
import AppKit
import CoreGraphics
import Foundation
import LaserGuideCore

public final class PermissionMonitor {

    /// Accessibility 権限の有無。prompt=true で初回はシステムダイアログを出す。
    public static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private var monitor: Any?

    /// レーザー描画のみ mode: NSEvent global monitor でマウス位置を購読して viewModel に流す。
    /// NSEvent.mouseLocation は y-up bottom-left なので primary NSScreen の高さで CG y-down に変換する。
    public func startLaserOnly(onMove: @escaping (LogicalPoint) -> Void) {
        stopLaserOnly()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { _ in
            let cg = Self.nsScreenPointToCG(NSEvent.mouseLocation)
            onMove(LogicalPoint(x: Double(cg.x), y: Double(cg.y)))
        }
    }

    public func stopLaserOnly() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// NSEvent y-up (bottom-left) → CG y-down (top-left)。
    /// DR-0005 の変換式 `cgY = primaryHeight - nsY` (x は同じ)。
    ///
    /// 基準高さは **primary スクリーン (= NSScreen.screens.first、Cocoa 座標原点 (0,0) を持つ画面)**
    /// でなければならない。`NSScreen.main` は「キーボードフォーカスのあるウィンドウのスクリーン」で
    /// あり座標原点とは無関係 — 2026-07-10 実機第 3 ラウンド #2 で、フォーカス画面と primary の
    /// 高さ差の分だけクリックサークルが下にズレる bug の原因だった。
    static func nsScreenPointToCG(_ nsPoint: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return nsScreenPointToCG(nsPoint, primaryHeight: primaryHeight)
    }

    /// 変換式の純関数部 (テスト用に高さを注入可能)。
    static func nsScreenPointToCG(_ nsPoint: NSPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: nsPoint.x, y: primaryHeight - nsPoint.y)
    }
}
