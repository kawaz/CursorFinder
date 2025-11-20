// Point2D.swift
import Foundation

/// 2次元座標点（物理座標用）
struct Point2D: Codable, Hashable {
    var x: Double
    var y: Double

    /// ゼロ点
    static var zero: Point2D {
        Point2D(x: 0, y: 0)
    }

    /// CGPointから変換
    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// CGPointに変換
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    /// ベクトル演算
    static func + (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: Point2D, rhs: Double) -> Point2D {
        Point2D(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    static func / (lhs: Point2D, rhs: Double) -> Point2D {
        Point2D(x: lhs.x / rhs, y: lhs.y / rhs)
    }

    /// 距離計算
    func distance(to other: Point2D) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return sqrt(dx * dx + dy * dy)
    }
}
