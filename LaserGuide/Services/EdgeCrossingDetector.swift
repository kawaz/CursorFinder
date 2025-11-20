// EdgeCrossingDetector.swift
import Cocoa

/// エッジ越境検出サービス
class EdgeCrossingDetector {
    static let shared = EdgeCrossingDetector()
    
    private let displayDetector = DisplayDetector.shared
    private let mouseTracker = MouseTracker.shared
    
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
            $0.logicalFrame.contains(position)
        }) else {
            return nil
        }
        
        let frame = currentDisplay.logicalFrame
        let relativeX = position.x - frame.minX
        let relativeY = position.y - frame.minY
        
        // 各エッジとの距離をチェック
        if relativeY <= threshold {
            // Bottom edge
            let normalizedPos = relativeX / frame.width
            return (currentDisplay.id, .bottom, normalizedPos)
        } else if relativeY >= frame.height - threshold {
            // Top edge
            let normalizedPos = relativeX / frame.width
            return (currentDisplay.id, .top, normalizedPos)
        } else if relativeX <= threshold {
            // Left edge
            let normalizedPos = relativeY / frame.height
            return (currentDisplay.id, .left, normalizedPos)
        } else if relativeX >= frame.width - threshold {
            // Right edge
            let normalizedPos = relativeY / frame.height
            return (currentDisplay.id, .right, normalizedPos)
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
        let navigation = workspace.configuration.navigation
        
        // EdgeNavigationMapで越境処理
        guard let (targetEdge, targetNormalizedPos) = navigation.handleCrossing(
            at: position,
            displayId: displayId,
            side: side
        ) else {
            NSLog("🚫 Block: displayId=\(displayId), side=\(side), pos=\(String(format: "%.3f", position))")
            return nil
        }
        
        // 越境先のディスプレイを取得
        guard let targetDisplay = workspace.displays.first(where: {
            $0.id == targetEdge.displayId
        }) else {
            NSLog("❌ 越境先ディスプレイが見つかりません: \(targetEdge.displayId)")
            return nil
        }
        
        // 越境先の座標を計算
        let targetFrame = targetDisplay.logicalFrame
        let targetPosition: CGPoint
        
        switch targetEdge.side {
        case .top:
            // Top edge: X軸で位置を決定
            targetPosition = CGPoint(
                x: targetFrame.minX + targetNormalizedPos * targetFrame.width,
                y: targetFrame.maxY
            )
        case .bottom:
            // Bottom edge: X軸で位置を決定
            targetPosition = CGPoint(
                x: targetFrame.minX + targetNormalizedPos * targetFrame.width,
                y: targetFrame.minY
            )
        case .left:
            // Left edge: Y軸で位置を決定
            targetPosition = CGPoint(
                x: targetFrame.minX,
                y: targetFrame.minY + targetNormalizedPos * targetFrame.height
            )
        case .right:
            // Right edge: Y軸で位置を決定
            targetPosition = CGPoint(
                x: targetFrame.maxX,
                y: targetFrame.minY + targetNormalizedPos * targetFrame.height
            )
        }
        
        NSLog("✅ 越境: \(side) -> \(targetEdge.side), pos=\(String(format: "%.3f", targetNormalizedPos))")
        
        return (targetDisplay, targetPosition)
    }
}

