// OverlayWindowController (v1 ScreenManager の完成品設定をそのまま流用)
//
// - NSWindow: borderless, clear, ignoresMouseEvents, sharingType=.none (スクショ除外),
//   level=assistiveTechHighWindow, collectionBehavior 全 space
// - 1 CGDirectDisplayID につき 1 window。NSScreen 突合はデバイス記述の "NSScreenNumber" キーで行う
// - view は LaserOverlayView (SwiftUI Canvas)、NSHostingController でラップする
import AppKit
import SwiftUI
import CoreGraphics
import LaserGuideCore

public final class OverlayWindowController {

    public let displayId: String
    public let cgDisplayId: CGDirectDisplayID
    public let window: NSWindow
    public let viewModel: OverlayViewModel
    private let hosting: NSHostingController<LaserOverlayView>

    public init?(displayId: String, cgDisplayId: CGDirectDisplayID, model: OverlayViewModel) {
        self.displayId = displayId
        self.cgDisplayId = cgDisplayId
        self.viewModel = model
        guard let screen = Self.nsScreen(for: cgDisplayId) else { return nil }

        let view = LaserOverlayView(displayId: displayId, model: model)
        self.hosting = NSHostingController(rootView: view)

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.displaysWhenScreenProfileChanges = false
        win.allowsConcurrentViewDrawing = true
        win.sharingType = .none
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        win.contentViewController = hosting
        win.setFrame(screen.frame, display: true)
        self.window = win
    }

    public func show() { window.orderFrontRegardless() }
    public func hide() { window.orderOut(nil) }

    /// CGDirectDisplayID に一致する NSScreen を探す (deviceDescription["NSScreenNumber"])。
    static func nsScreen(for cgId: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let n = screen.deviceDescription[key] as? NSNumber {
                return n.uint32Value == cgId
            }
            return false
        }
    }
}
