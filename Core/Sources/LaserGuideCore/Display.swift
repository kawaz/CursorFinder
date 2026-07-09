// Display (幾何コアが扱う 1 モニタの入力)
//
// - id: hardwareId 相当の永続識別子 (DR-0007)
// - logicalBounds: CG グローバル論理座標での配置 (px, y-down)
// - pose: 論理→物理 mm への変換 (DR-0005)
//
// 辺の along-edge レンジ (top/bottom は x、left/right は y) は logicalBounds から派生。
import Foundation

public struct Display: Equatable, Hashable, Sendable {
    public let id: String
    public var logicalBounds: LogicalRect
    public var pose: DisplayPose

    public init(id: String, logicalBounds: LogicalRect, pose: DisplayPose) {
        self.id = id
        self.logicalBounds = logicalBounds
        self.pose = pose
    }

    /// 指定した辺の along-edge 論理レンジ (px)。top/bottom → x レンジ、left/right → y レンジ。
    public func alongEdgeLogicalRange(_ side: Side) -> ClosedRange<Double> {
        switch side {
        case .top, .bottom: return logicalBounds.minX...logicalBounds.maxX
        case .left, .right: return logicalBounds.minY...logicalBounds.maxY
        }
    }

    /// 指定した辺の「固定座標軸」の論理値。top → minY、bottom → maxY、left → minX、right → maxX。
    public func edgeFixedLogicalCoord(_ side: Side) -> Double {
        switch side {
        case .top: return logicalBounds.minY
        case .bottom: return logicalBounds.maxY
        case .left: return logicalBounds.minX
        case .right: return logicalBounds.maxX
        }
    }
}
