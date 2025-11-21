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
            return (currentDisplay.id, .bottom, relativeX)
        } else if relativeY >= frame.size.height - threshold {
            // Top edge
            return (currentDisplay.id, .top, relativeX)
        } else if relativeX <= threshold {
            // Left edge
            return (currentDisplay.id, .left, relativeY)
        } else if relativeX >= frame.size.width - threshold {
            // Right edge
            return (currentDisplay.id, .right, relativeY)
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
}

