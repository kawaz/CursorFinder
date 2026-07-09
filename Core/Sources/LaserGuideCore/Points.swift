// 座標型 (DR-0005: 論理/物理を型で分離する)
//
// - LogicalPoint / LogicalRect: CG グローバル論理座標 (top-left 原点、y-down、px)
// - PhysicalPoint / PhysicalRect: 物理配置空間 (mm)
//
// 論理と物理を同じ型にすると V3 のようにキャリブレーションで即破綻する。
// 型で分離することで混用をコンパイルエラー化する (DR-0005 決定 2)。
//
// Rect は minX/minY/maxX/maxY で保持。y-down 規約なので Top 辺 = minY 側。
import Foundation

public struct LogicalPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PhysicalPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct LogicalRect: Equatable, Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    // y-down 半開区間包含: 通常の CG 慣習に合わせ minX <= p.x < maxX, minY <= p.y < maxY。
    // ただし境界厳密判定 (BX 等) は containsClosed / onEdge で扱う。
    public func containsHalfOpen(_ p: LogicalPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }
    public func containsClosed(_ p: LogicalPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

public struct PhysicalRect: Equatable, Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
}
