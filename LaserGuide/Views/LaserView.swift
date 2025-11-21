// LaserView.swift
import SwiftUI
import SpriteKit

/// レーザー表示ビュー
struct LaserView: View {
    let display: Display
    @ObservedObject private var mouseTracker = MouseTracker.shared
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // SpriteKitシーン
                if mouseTracker.isMouseActive {
                    SpriteView(scene: createScene(size: geometry.size))
                        .ignoresSafeArea()
                }
            }
        }
    }
    
    private func createScene(size: CGSize) -> SKScene {
        let scene = LaserScene(display: display, size: size)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = .clear
        return scene
    }
}

/// レーザーシーン（SpriteKit）
class LaserScene: SKScene {
    private let display: Display
    private let mouseTracker = MouseTracker.shared
    private var laserNodes: [SKShapeNode] = []
    
    init(display: Display, size: CGSize) {
        self.display = display
        super.init(size: size)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func didMove(to view: SKView) {
        // 透明な背景
        backgroundColor = .clear
        
        // レーザーノードを作成（4つのコーナーから）
        for _ in 0..<4 {
            let node = SKShapeNode()
            addChild(node)
            laserNodes.append(node)
        }
    }
    
    override func update(_ currentTime: TimeInterval) {
        guard mouseTracker.isMouseActive else {
            // 非アクティブ時はレーザーを非表示
            laserNodes.forEach { $0.isHidden = true }
            return
        }
        
        let mouseLocation = mouseTracker.currentMouseLocation
        
        // マウスがこのディスプレイ上にあるかチェック
        let frame = display.coordinates.logical
        let isOnThisDisplay = mouseLocation.x >= frame.position.x && 
                             mouseLocation.x < frame.position.x + frame.size.width &&
                             mouseLocation.y >= frame.position.y && 
                             mouseLocation.y < frame.position.y + frame.size.height
        
        if isOnThisDisplay {
            // このディスプレイ上にマウスがある場合、レーザーを表示
            updateLasers(mouseLocation: mouseLocation)
        } else {
            // 他のディスプレイ上にある場合は非表示
            laserNodes.forEach { $0.isHidden = true }
        }
    }
    
    private func updateLasers(mouseLocation: CGPoint) {
        // ローカル座標に変換（SpriteKitは左下原点なので論理座標と同じ）
        let frame = display.coordinates.logical
        let localX = mouseLocation.x - frame.position.x
        let localY = mouseLocation.y - frame.position.y
        let targetPoint = CGPoint(x: localX, y: localY)
        
        // 4つのコーナー
        let corners = [
            CGPoint(x: 0, y: 0),                          // 左下
            CGPoint(x: frame.size.width, y: 0),          // 右下
            CGPoint(x: 0, y: frame.size.height),         // 左上
            CGPoint(x: frame.size.width, y: frame.size.height)  // 右上
        ]
        
        // 各コーナーからレーザーを描画
        for (index, corner) in corners.enumerated() {
            let path = createLaserPath(from: corner, to: targetPoint)
            
            laserNodes[index].path = path
            laserNodes[index].fillColor = NSColor.blue.withAlphaComponent(0.3)
            laserNodes[index].strokeColor = .clear
            laserNodes[index].isHidden = false
        }
    }
    
    private func createLaserPath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        
        // 台形のレーザーライン
        let cornerWidth: CGFloat = 8.0
        let targetWidth: CGFloat = 0.5
        
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        
        guard distance > 1.0 else {
            return path
        }
        
        // 正規化された垂直ベクトル
        let perpX = -dy / distance
        let perpY = dx / distance
        
        // 台形の4頂点
        let c1 = CGPoint(x: start.x + perpX * cornerWidth, y: start.y + perpY * cornerWidth)
        let c2 = CGPoint(x: start.x - perpX * cornerWidth, y: start.y - perpY * cornerWidth)
        let t1 = CGPoint(x: end.x + perpX * targetWidth, y: end.y + perpY * targetWidth)
        let t2 = CGPoint(x: end.x - perpX * targetWidth, y: end.y - perpY * targetWidth)
        
        path.move(to: c1)
        path.addLine(to: t1)
        path.addLine(to: t2)
        path.addLine(to: c2)
        path.closeSubpath()
        
        return path
    }
}

