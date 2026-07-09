// トリガー分類 (DR-0004 高頻度経路 / DR-0006 BX の入力契約)
//
// fast path で毎イベント行う 3 分類:
//   - interior: 同一モニタ内の移動 (追加処理なし)
//   - PX: 所属モニタ id が変わった (= ネイティブ通過が起きた)
//         crossing 線分を持って slow path へ
//   - BX: current がエッジ上、かつ delta の符号が外向き (= ネイティブブロックに当たった)
//         (display, sides) を持って slow path へ。sides は優先度順の候補リスト (M-2)
//
// delta は「符号のみ」に依存する契約 (DR-0006 決定 3)。大きさに触らない。
// エッジ上を滑る動き (delta が接線方向のみ) は BX にしない。
// 角の斜め越境で複数 side が候補になる場合、ここでは優先度順 top→bottom→left→right で
// **全候補を列挙** する (単一 side に絞らない、m-2)。実機観測 (findings §5e: カドで両軸の delta が
// 流れ続ける) では優先辺が userSegment を持たず block、次候補辺が BP という構成がありうるため、
// 候補を残したまま Judgement.judgeBlockedWithFallback に渡し、そちらで 2 段評価する。
//
// エッジ判定 ε (docs/findings/2026-07-09-macos-display-api-verification.md §4 の実機観測):
//   OS の CGEventTap クランプは min 側エッジは境界値ちょうど (例: x=0.00) に落ちるが、
//   max 側エッジは境界値 − 0.02 px (例: x=2055.98) に落ちる。座標は Double で小数を持つ。
//   よって「エッジ上」の判定は == では書けず、ε 近傍 (デフォルト 0.1 px、API で調整可能) で行う。
import Foundation

public struct LineSegment: Equatable, Hashable, Sendable {
    public var from: LogicalPoint
    public var to: LogicalPoint
    public init(from: LogicalPoint, to: LogicalPoint) { self.from = from; self.to = to }
}

public enum MoveClass: Equatable, Hashable, Sendable {
    case interior
    case px(crossing: LineSegment, previousDisplayId: String, currentDisplayId: String?)
    /// sides は優先度順 (top→bottom→left→right) の候補リスト、非空。カドでは複数 side を含む (m-2)。
    case bx(displayId: String, sides: [Side])
}

public enum Trigger {

    /// エッジ判定の許容誤差デフォルト値 (px)。実機観測 (max 側 -0.02 px オフセット) を吸収する幅。
    /// 0.1 は「実測 0.02 に十分な余裕を持たせつつ、モニタ内 1 px の粒度は区別できる」中間値。
    public static let defaultEdgeEpsilon: Double = 0.1

    /// 2 世代履歴とその瞬間の delta 符号から移動を 3 分類する。
    /// - Parameter edgeEpsilon: BX 判定でエッジ上とみなす許容誤差 (px)。実機 CGEventTap の
    ///   クランプは max 側で境界値 − 0.02 px に落ちるため、== 比較では BX を取り逃す。
    /// - Parameter tables: 所属モニタの探索に displays を使う (m-7: WarpTables を受ける形に統一し、
    ///   呼び出し側が displays 配列を個別に取り回す必要をなくす)。
    public static func classify(
        prev: (point: LogicalPoint, displayId: String?),
        current: (point: LogicalPoint, displayId: String?),
        deltaSign: (dx: Int, dy: Int),
        tables: WarpTables,
        edgeEpsilon: Double = Trigger.defaultEdgeEpsilon
    ) -> MoveClass {
        // PX: 所属モニタ id 変化。prev.displayId が nil (初回など) の時は PX ではなく interior 扱い。
        if let prevId = prev.displayId, prev.displayId != current.displayId {
            return .px(
                crossing: LineSegment(from: prev.point, to: current.point),
                previousDisplayId: prevId,
                currentDisplayId: current.displayId
            )
        }
        // BX: current がエッジ上 (ε 近傍) + delta 符号が外向き。優先度は top → bottom → left → right。
        // カドでは複数 side が同時に候補になりうるので、最初の 1 件で打ち切らず全候補を集める (m-2)。
        if let curId = current.displayId,
           let d = tables.display(curId) {
            let priorities: [Side] = [.top, .bottom, .left, .right]
            let matched = priorities.filter { side in
                isOnEdge(current.point, display: d, side: side, epsilon: edgeEpsilon) &&
                    isDeltaOutward(deltaSign, side: side)
            }
            if !matched.isEmpty {
                return .bx(displayId: curId, sides: matched)
            }
        }
        return .interior
    }

    // ================================
    // internal 補助
    // ================================

    /// 点 p が display の指定 side 上にあるかを ε 近傍で判定する。
    /// - 「固定軸」は abs(p.axis - edgeCoord) <= epsilon で判定 (実機 max 側 -0.02 px オフセット吸収)
    /// - 「along-edge 軸」は矩形の範囲内であること (こちらは通常 OS 出力が矩形内に収まるので厳密)
    internal static func isOnEdge(_ p: LogicalPoint, display d: Display, side: Side, epsilon: Double) -> Bool {
        let b = d.logicalBounds
        switch side {
        case .top:    return abs(p.y - b.minY) <= epsilon && p.x >= b.minX - epsilon && p.x <= b.maxX + epsilon
        case .bottom: return abs(p.y - b.maxY) <= epsilon && p.x >= b.minX - epsilon && p.x <= b.maxX + epsilon
        case .left:   return abs(p.x - b.minX) <= epsilon && p.y >= b.minY - epsilon && p.y <= b.maxY + epsilon
        case .right:  return abs(p.x - b.maxX) <= epsilon && p.y >= b.minY - epsilon && p.y <= b.maxY + epsilon
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
