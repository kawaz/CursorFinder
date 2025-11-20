// ScreenManager.swift
import SwiftUI

class ScreenManager: ObservableObject {
    static let shared = ScreenManager()

    @Published var overlayWindows: [NSWindow] = []
    var hostingControllers: [NSHostingController<LaserOverlayView>] = []  // Public for CalibrationViewModel access

    private init() {
        setupOverlays()
    }

    func setupOverlays() {
        removeOverlays()

        for (index, screen) in NSScreen.screens.enumerated() {
            let screenNumber = index + 1  // 1-based screen number
            let viewModel = LaserViewModel(screenNumber: screenNumber)
            let overlayView = LaserOverlayView(viewModel: viewModel, screen: screen)
            let hostingController = NSHostingController(rootView: overlayView)

            let window = createOverlayWindow(for: screen)
            window.contentViewController = hostingController
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)

            viewModel.startTracking()
            overlayWindows.append(window)
            hostingControllers.append(hostingController)  // Keep strong reference
        }
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // 基本設定
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true

        // パフォーマンス最適化
        window.displaysWhenScreenProfileChanges = false
        window.allowsConcurrentViewDrawing = true

        // スクリーンショット除外
        window.sharingType = .none

        // Core Animation設定
        if Config.Performance.useCoreAnimationLayers {
            window.contentView?.wantsLayer = true

            if let layer = window.contentView?.layer {
                layer.isOpaque = false
                layer.drawsAsynchronously = true
                layer.contentsScale = window.backingScaleFactor

                // Metal レンダリング（最新の最適化）
                if #available(macOS 10.14, *) {
                    layer.contentsFormat = .RGBA8Uint  // または .RGBA16Float for HDR
                    // layer.acceleratesDisplay = true  // これも非推奨の可能性
                }
            }
        }

        // レベルとビヘイビア
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow))
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        return window
    }

    func removeOverlays() {
        for controller in hostingControllers {
            controller.rootView.viewModel.stopTracking()
        }
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        hostingControllers.removeAll()
    }

}
