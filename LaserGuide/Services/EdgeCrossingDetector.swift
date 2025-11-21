// EdgeCrossingDetector.swift
import Cocoa

/// エッジ越境検出サービス
class EdgeCrossingDetector {
    static let shared = EdgeCrossingDetector()

    private let displayDetector = DisplayDetector.shared
    private let mouseTracker = MouseTracker.shared
    
    // CGEventTap関連
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled: Bool = false
    
    // エッジ検出の閾値
    private let edgeThreshold: CGFloat = 5.0
    
    // デバッグ用: 越境カウント
    private var crossingCount: Int = 0

    private init() {}

    /// エッジ付近かチェック
    /// - Parameters:
    ///   - position: マウス位置（グローバル座標）
    ///   - threshold: エッジからの距離閾値（ピクセル）
    /// - Returns: エッジ情報（displayId, side, 正規化位置）
    func detectEdgeProximity(
        at position: CGPoint,
        threshold: CGFloat = 5.0
    ) -> (displayId: UUID, side: EdgeSide, normalizedPosition: Double)? {

        let workspace = displayDetector.workspace

        // マウスがどのディスプレイにいるか判定
        guard let currentDisplay = workspace.displays.first(where: {
            let frame = $0.coordinates.logical
            return position.x >= frame.position.x && position.x < frame.position.x + frame.size.width &&
                   position.y >= frame.position.y && position.y < frame.position.y + frame.size.height
        }) else {
            return nil
        }

        let frame = currentDisplay.coordinates.logical
        let relativeX = position.x - frame.position.x
        let relativeY = position.y - frame.position.y

        // 各エッジとの距離をチェック（実座標値を返す）
        if relativeY <= threshold {
            // Bottom edge
            return (currentDisplay.id, .bottom, Double(relativeX))
        } else if relativeY >= frame.size.height - threshold {
            // Top edge
            return (currentDisplay.id, .top, Double(relativeX))
        } else if relativeX <= threshold {
            // Left edge
            return (currentDisplay.id, .left, Double(relativeY))
        } else if relativeX >= frame.size.width - threshold {
            // Right edge
            return (currentDisplay.id, .right, Double(relativeY))
        }

        return nil
    }

    /// 越境を処理
    /// - Parameters:
    ///   - displayId: 現在のディスプレイID
    ///   - side: エッジの辺
    ///   - position: 正規化された位置（0.0〜1.0）
    /// - Returns: 越境先の情報（成功時）またはnil（Block時）
    func handleCrossing(
        displayId: UUID,
        side: EdgeSide,
        position: Double
    ) -> (targetDisplay: Display, targetPosition: CGPoint)? {

        // 強制Block状態のチェック
        if mouseTracker.shouldForceBlock {
            NSLog("🚫 強制Block（修飾キー押下中）")
            return nil
        }

        let workspace = displayDetector.workspace
        let navigationMap = EdgeNavigationMap(displays: workspace.displays)

        // EdgeNavigationMapで越境処理
        guard let (targetDisplay, targetPosition) = navigationMap.handleCrossing(
            at: position,
            displayId: displayId,
            side: side
        ) else {
            NSLog("🚫 Block: displayId=\(displayId), side=\(side), pos=\(String(format: "%.1f", position))")
            return nil
        }

        // 論理座標に変換
        let targetFrame = targetDisplay.coordinates.logical
        let targetPoint = CGPoint(
            x: targetFrame.position.x + targetPosition,
            y: targetFrame.position.y
        )

        NSLog("✅ 越境成功: pos=\(String(format: "%.1f", targetPosition))")

        return (targetDisplay, targetPoint)
    }
    
    /// エッジ越境監視を開始
    func startMonitoring() {
        guard !isEnabled else {
            NSLog("⚠️ EdgeCrossingDetector already started")
            return
        }
        
        // アクセシビリティ権限チェック
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        guard isTrusted else {
            NSLog("❌ アクセシビリティ権限が必要です")
            return
        }
        
        // CGEventTapを作成
        let eventMask = (1 << CGEventType.mouseMoved.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let detector = Unmanaged<EdgeCrossingDetector>.fromOpaque(refcon).takeUnretainedValue()
                return detector.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("❌ CGEventTap の作成に失敗")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isEnabled = true
            NSLog("✅ EdgeCrossingDetector started")
        } else {
            NSLog("❌ RunLoopSource の作成に失敗")
        }
    }
    
    /// エッジ越境監視を停止
    func stopMonitoring() {
        guard isEnabled else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isEnabled = false
        NSLog("🛑 EdgeCrossingDetector stopped")
    }
    
    /// マウスイベントハンドラ
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // エッジナビゲーションが無効の場合はスルー
        guard let appConfig = AppConfigurationManager.shared.loadConfiguration(),
              appConfig.edgeNavigation.enabled else {
            return Unmanaged.passRetained(event)
        }
        
        // 現在のマウス位置を取得
        let location = event.location
        
        // エッジ付近かチェック
        guard let edgeInfo = detectEdgeProximity(at: location, threshold: edgeThreshold) else {
            return Unmanaged.passRetained(event)
        }
        
        // 越境処理
        guard let (targetDisplay, targetPosition) = handleCrossing(
            displayId: edgeInfo.displayId,
            side: edgeInfo.side,
            position: edgeInfo.normalizedPosition
        ) else {
            // Block時はそのまま返す（エッジでストップ）
            return Unmanaged.passRetained(event)
        }
        
        // マウス座標を書き換え
        event.location = targetPosition
        crossingCount += 1
        
        NSLog("🚀 越境実行 [\(crossingCount)]: \(edgeInfo.side) → \(targetDisplay.display.name) @ (\(String(format: "%.1f", targetPosition.x)), \(String(format: "%.1f", targetPosition.y)))")
        
        return Unmanaged.passRetained(event)
    }
    
    deinit {
        stopMonitoring()
    }
}
