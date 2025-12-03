// PhysicalLayoutScene.swift
import SpriteKit

/// 物理配置編集用のSpriteKitシーン
/// 座標系: 左下原点、Y軸上向き（SpriteKit標準）
class PhysicalLayoutScene: SKScene {

    // MARK: - Properties

    /// 編集中のディスプレイデータ
    var displays: [Display] = [] {
        didSet { updateDisplayNodes() }
    }

    /// 変更通知用クロージャ
    var onDisplaysChanged: (([Display]) -> Void)?

    /// フォーカス状態変更通知（ドラッグ中のディスプレイID、nilでフォーカスなし）
    var onFocusChanged: ((UUID?) -> Void)?

    /// ディスプレイノードのマップ
    private var displayNodes: [UUID: DisplayNode] = [:]

    /// 現在ドラッグ中のノード
    private var draggingNode: DisplayNode?

    /// ドラッグ開始時のオフセット
    private var dragOffset: CGPoint = .zero

    /// スケール（mm → points）
    private var displayScale: CGFloat = 1.0

    /// キャンバスマージン
    private let canvasMargin: CGFloat = 40

    // MARK: - Scene Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = NSColor.windowBackgroundColor
        updateDisplayNodes()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        updateDisplayNodes()
    }

    // MARK: - Display Node Management

    private func updateDisplayNodes() {
        // 既存ノードをクリア
        displayNodes.values.forEach { $0.removeFromParent() }
        displayNodes.removeAll()

        guard !displays.isEmpty, size.width > 0, size.height > 0 else { return }

        // スケール計算
        calculateScale()

        // ディスプレイノードを作成
        for (index, display) in displays.enumerated() {
            let node = DisplayNode(display: display, colorIndex: index, scale: displayScale)
            // ノードの中心位置を設定（SKShapeNode(rectOf:)は中心基準）
            let physicalCenter = CGPoint(
                x: display.coordinates.physical.position.x + display.coordinates.physical.size.width / 2,
                y: display.coordinates.physical.position.y + display.coordinates.physical.size.height / 2
            )
            node.position = physicalToScene(physicalCenter)
            addChild(node)
            displayNodes[display.id] = node
        }
    }

    private func calculateScale() {
        let bounds = physicalBounds
        guard bounds.width > 0, bounds.height > 0 else {
            displayScale = 1.0
            return
        }

        let availableWidth = size.width - canvasMargin * 2
        let availableHeight = size.height - canvasMargin * 2

        let scaleX = availableWidth / bounds.width
        let scaleY = availableHeight / bounds.height

        displayScale = min(scaleX, scaleY)
    }

    /// 物理座標の全体バウンディングボックス
    private var physicalBounds: CGRect {
        guard !displays.isEmpty else { return .zero }

        let minX = displays.map { $0.coordinates.physical.position.x }.min() ?? 0
        let minY = displays.map { $0.coordinates.physical.position.y }.min() ?? 0
        let maxX = displays.map { $0.coordinates.physical.position.x + $0.coordinates.physical.size.width }.max() ?? 0
        let maxY = displays.map { $0.coordinates.physical.position.y + $0.coordinates.physical.size.height }.max() ?? 0

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Coordinate Conversion

    /// 物理座標（mm）からシーン座標へ
    private func physicalToScene(_ point: CGPoint) -> CGPoint {
        let bounds = physicalBounds
        let offsetX = canvasMargin + (size.width - canvasMargin * 2 - bounds.width * displayScale) / 2
        let offsetY = canvasMargin + (size.height - canvasMargin * 2 - bounds.height * displayScale) / 2

        return CGPoint(
            x: offsetX + (point.x - bounds.minX) * displayScale,
            y: offsetY + (point.y - bounds.minY) * displayScale
        )
    }

    /// シーン座標から物理座標（mm）へ
    private func sceneToPhysical(_ point: CGPoint) -> CGPoint {
        let bounds = physicalBounds
        let offsetX = canvasMargin + (size.width - canvasMargin * 2 - bounds.width * displayScale) / 2
        let offsetY = canvasMargin + (size.height - canvasMargin * 2 - bounds.height * displayScale) / 2

        return CGPoint(
            x: bounds.minX + (point.x - offsetX) / displayScale,
            y: bounds.minY + (point.y - offsetY) / displayScale
        )
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)

        // ディスプレイノードをタップしたか判定
        for (_, node) in displayNodes {
            if node.contains(location) {
                draggingNode = node
                dragOffset = CGPoint(
                    x: node.position.x - location.x,
                    y: node.position.y - location.y
                )
                node.startDragging()
                onFocusChanged?(node.displayId)
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node = draggingNode else { return }

        let location = event.location(in: self)
        node.position = CGPoint(
            x: location.x + dragOffset.x,
            y: location.y + dragOffset.y
        )

        // 物理座標を更新（リアルタイム表示用、中心から左下角へ変換）
        let physicalCenter = sceneToPhysical(node.position)
        let physicalPos = CGPoint(
            x: physicalCenter.x - node.physicalSize.width / 2,
            y: physicalCenter.y - node.physicalSize.height / 2
        )
        node.updateCoordinateLabel(physicalPos)
    }

    override func mouseUp(with event: NSEvent) {
        guard let node = draggingNode else { return }

        node.stopDragging()

        // 物理座標を確定（中心から左下角へ変換）
        let physicalCenter = sceneToPhysical(node.position)
        let physicalPos = CGPoint(
            x: physicalCenter.x - node.physicalSize.width / 2,
            y: physicalCenter.y - node.physicalSize.height / 2
        )

        // displaysを更新
        if let index = displays.firstIndex(where: { $0.id == node.displayId }) {
            displays[index].coordinates.physical.position = physicalPos
        }

        // 正規化
        normalizePhysicalPositions()

        // 変更通知
        onDisplaysChanged?(displays)

        // ノード位置を再計算（正規化後）
        updateDisplayNodes()

        draggingNode = nil

        // フォーカス解除
        onFocusChanged?(nil)
    }

    // MARK: - Position Normalization

    private func normalizePhysicalPositions() {
        guard !displays.isEmpty else { return }

        let minX = displays.map { $0.coordinates.physical.position.x }.min() ?? 0
        let minY = displays.map { $0.coordinates.physical.position.y }.min() ?? 0

        for i in displays.indices {
            displays[i].coordinates.physical.position.x -= minX
            displays[i].coordinates.physical.position.y -= minY
        }
    }
}

// MARK: - DisplayNode

/// ディスプレイを表すノード
class DisplayNode: SKNode {
    let displayId: UUID
    let physicalSize: CGSize  // 物理サイズ（mm）
    private let backgroundNode: SKShapeNode
    private let coordinateLabel: SKLabelNode
    private let displayColor: NSColor
    private let nodeSize: CGSize

    init(display: Display, colorIndex: Int, scale: CGFloat) {
        self.displayId = display.id
        self.physicalSize = display.coordinates.physical.size

        // 色の選択
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemRed, .systemTeal]
        self.displayColor = colors[colorIndex % colors.count]

        // 背景ノード
        let physicalSize = display.coordinates.physical.size
        self.nodeSize = CGSize(width: physicalSize.width * scale, height: physicalSize.height * scale)

        backgroundNode = SKShapeNode(rectOf: nodeSize, cornerRadius: 4)
        backgroundNode.fillColor = displayColor.withAlphaComponent(0.2)
        backgroundNode.strokeColor = displayColor
        backgroundNode.lineWidth = 2

        // 座標ラベル（左下コーナー）
        let pos = display.coordinates.physical.position
        coordinateLabel = SKLabelNode(text: "(\(Int(pos.x)), \(Int(pos.y)))")
        coordinateLabel.fontName = "Menlo"
        coordinateLabel.fontSize = 9
        coordinateLabel.fontColor = .white
        coordinateLabel.verticalAlignmentMode = .bottom
        coordinateLabel.horizontalAlignmentMode = .left

        super.init()

        addChild(backgroundNode)

        coordinateLabel.position = CGPoint(x: -nodeSize.width / 2 + 4, y: -nodeSize.height / 2 + 4)
        addChild(coordinateLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func contains(_ p: CGPoint) -> Bool {
        let local = convert(p, from: parent!)
        return backgroundNode.contains(local)
    }

    func startDragging() {
        backgroundNode.glowWidth = 4
        run(SKAction.scale(to: 1.05, duration: 0.1))
    }

    func stopDragging() {
        backgroundNode.glowWidth = 0
        run(SKAction.scale(to: 1.0, duration: 0.1))
    }

    func updateCoordinateLabel(_ position: CGPoint) {
        coordinateLabel.text = "(\(Int(position.x)), \(Int(position.y)))"
    }
}
