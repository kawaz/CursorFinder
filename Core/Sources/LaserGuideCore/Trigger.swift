// トリガー分類 (DR-0004 高頻度経路 / DR-0006 BX の入力契約)
//
// fast path で毎イベント行う 3 分類:
//   - interior: 同一モニタ内の移動 (追加処理なし)
//   - PX: 所属モニタ id が変わった (= ネイティブ通過が起きた)
//         crossing 線分を持って slow path へ
//   - BX: current がエッジ上、かつ delta の符号が外向き (= ネイティブブロックに当たった)
//         (display, side) を持って slow path へ
//
// delta は「符号のみ」に依存する契約 (DR-0006 決定 3)。大きさに触らない。
// エッジ上を滑る動き (delta が接線方向のみ) は BX にしない。
// 角の斜め越境で複数 side が候補になる場合は優先度リスト top → bottom → left → right で決定的。
import Foundation

public struct LineSegment: Equatable, Hashable, Sendable {
    public var from: LogicalPoint
    public var to: LogicalPoint
    public init(from: LogicalPoint, to: LogicalPoint) { self.from = from; self.to = to }
}

public enum MoveClass: Equatable, Hashable, Sendable {
    case interior
    case px(crossing: LineSegment, previousDisplayId: String, currentDisplayId: String?)
    case bx(displayId: String, side: Side)
}

public enum Trigger {
    /// 2 世代履歴とその瞬間の delta 符号から移動を 3 分類する。
    public static func classify(
        prev: (point: LogicalPoint, displayId: String?),
        current: (point: LogicalPoint, displayId: String?),
        deltaSign: (dx: Int, dy: Int),
        displays: [Display]
    ) -> MoveClass {
        // PX: 所属モニタ id 変化。prev.displayId が nil (初回など) の時は PX ではなく interior 扱い。
        if let prevId = prev.displayId, prev.displayId != current.displayId {
            return .px(
                crossing: LineSegment(from: prev.point, to: current.point),
                previousDisplayId: prevId,
                currentDisplayId: current.displayId
            )
        }
        // BX: current がエッジ上 + delta 符号が外向き。優先度は top → bottom → left → right。
        if let curId = current.displayId,
           let d = displays.first(where: { $0.id == curId }) {
            let priorities: [Side] = [.top, .bottom, .left, .right]
            for side in priorities {
                if isOnEdge(current.point, display: d, side: side) &&
                    isDeltaOutward(deltaSign, side: side) {
                    return .bx(displayId: curId, side: side)
                }
            }
        }
        return .interior
    }

    // ================================
    // internal 補助
    // ================================

    internal static func isOnEdge(_ p: LogicalPoint, display d: Display, side: Side) -> Bool {
        switch side {
        case .top:    return p.y == d.logicalBounds.minY && (d.logicalBounds.minX...d.logicalBounds.maxX).contains(p.x)
        case .bottom: return p.y == d.logicalBounds.maxY && (d.logicalBounds.minX...d.logicalBounds.maxX).contains(p.x)
        case .left:   return p.x == d.logicalBounds.minX && (d.logicalBounds.minY...d.logicalBounds.maxY).contains(p.y)
        case .right:  return p.x == d.logicalBounds.maxX && (d.logicalBounds.minY...d.logicalBounds.maxY).contains(p.y)
        }
    }

    internal static func isDeltaOutward(_ ds: (dx: Int, dy: Int), side: Side) -> Bool {
        switch side {
        case .top:    return ds.dy < 0  // 上 (y-down で minY 側) へ抜けようとしている
        case .bottom: return ds.dy > 0
        case .left:   return ds.dx < 0
        case .right:  return ds.dx > 0
        }
    }
}
