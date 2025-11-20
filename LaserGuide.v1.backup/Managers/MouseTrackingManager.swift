// MouseTrackingManager.swift
import SwiftUI
import Combine

/// システム全体のマウス追跡を管理するクラス
/// アプリケーションのフォーカス状態に依存せず、グローバルなマウスイベントを監視する
class MouseTrackingManager: ObservableObject {
    // MARK: - Published Properties
    @Published var currentMouseLocation: CGPoint = .zero
    @Published var isMouseActive: Bool = false

    // MARK: - Private Properties
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - Singleton
    static let shared = MouseTrackingManager()

    private init() {}

    // MARK: - Public Methods

    /// マウス追跡を開始する
    func startTracking() {
        stopTracking()
        setupGlobalMouseMonitor()
    }

    /// マウス追跡を停止する
    func stopTracking() {
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        if let monitor = localMouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMoveMonitor = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Private Methods

    private func setupGlobalMouseMonitor() {
        // グローバルモニター：他アプリのウィンドウ上でのマウス移動を監視
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMouseLocation(NSEvent.mouseLocation)
            }
        }

        // ローカルモニター：自アプリのウィンドウ上（キャリブレーション画面など）でのマウス移動を監視
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.updateMouseLocation(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func updateMouseLocation(_ location: CGPoint) {
        currentMouseLocation = location
        isMouseActive = true
        scheduleHideWithDebounce()
    }

    private func scheduleHideWithDebounce() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isMouseActive = false
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Config.Timing.inactivityThreshold,
            execute: workItem
        )
    }

    deinit {
        stopTracking()
    }
}
