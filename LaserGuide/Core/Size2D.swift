// Size2D.swift
import Foundation

/// 2次元サイズ（物理サイズ用）
struct Size2D: Codable, Hashable {
    var width: Double
    var height: Double

    /// ゼロサイズ
    static var zero: Size2D {
        Size2D(width: 0, height: 0)
    }

    /// CGSizeから変換
    init(_ size: CGSize) {
        self.width = Double(size.width)
        self.height = Double(size.height)
    }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// CGSizeに変換
    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    /// 面積
    var area: Double {
        width * height
    }

    /// アスペクト比
    var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return width / height
    }

    /// スケール演算
    static func * (lhs: Size2D, rhs: Double) -> Size2D {
        Size2D(width: lhs.width * rhs, height: lhs.height * rhs)
    }

    static func / (lhs: Size2D, rhs: Double) -> Size2D {
        Size2D(width: lhs.width / rhs, height: lhs.height / rhs)
    }
}
