// Side (DR-0005 y-down 規約)
//
// y-down なので Top 辺は minY 側、Bottom 辺は maxY 側。
// V3 moonbit/src/init.mbt は y-up 前提で書かれており、そのまま写経すると Top/Bottom が
// 反転してすべての上下越境が壊れる (2026-07 レビューで確認された Critical バグ)。
// ここで規約を型と定義で固定する。
import Foundation

public enum Side: String, Equatable, Hashable, Sendable, CaseIterable {
    case top     // y-down: 上辺 = y の小さい方 (minY)
    case bottom  // y-down: 下辺 = y の大きい方 (maxY)
    case left    // 左辺 = x の小さい方 (minX)
    case right   // 右辺 = x の大きい方 (maxX)

    /// 辺が水平か (top/bottom は x 軸に沿う)
    public var isHorizontal: Bool { self == .top || self == .bottom }

    /// 反対側の辺 (隣接する対向モニタのペア判定に使う)
    public var opposite: Side {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .right
        case .right: return .left
        }
    }
}
