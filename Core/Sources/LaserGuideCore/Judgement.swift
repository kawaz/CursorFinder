// ワープ判定 (DR-0006 の 4 状態デシジョンテーブル: PP/PB/BP/BB)
//
// 判定は「osSegments 集合 ∪ userSegments 集合」の所属差分で導出する:
//   PP (OS 通過・仮想通過): osSeg あり + userSeg あり → 何もしない
//   PB (OS 通過・仮想ブロック): osSeg あり + userSeg なし → クランプ差し戻し
//   BP (OS ブロック・仮想通過): osSeg なし + userSeg あり → 対向モニタへワープ
//   BB (両方ブロック): osSeg なし + userSeg なし → 何もしない
//
// PX 経路 (fast path 分類の PX) は OS が通したので osSeg は前提としてある。ここでは userSeg の
// 有無で PP / PB を分岐する。
// BX 経路は OS がブロックした = osSeg は少なくとも「その along 位置には」ない。userSeg の有無で
// BP / BB を分岐する。
//
// 同一エッジ上に複数セグメントが交点を含む場合、DR-0006 決定 5 の優先度リスト順で最初のものを
// 採用する = 現状は配列順を「優先度リスト」として扱い、first(where:) で決定的に決める。
import Foundation

/// PX (ネイティブ通過) 時のワープ判定結果
public enum CrossingJudgement: Equatable, Hashable, Sendable {
    case pp                                // 何もしない (OS の通過に任せる)
    case pb(clampTo: LogicalPoint)         // 仮想ブロック: 交点近傍にクランプ (source 内へ差し戻し)
    case noCrossing                        // 線分が OS の隣接エッジと交わらなかった (通常起きない)
}

/// BX (ネイティブブロック) 時のワープ判定結果
public enum BXOutcome: Equatable, Hashable, Sendable {
    case pass(warpTo: LogicalPoint)        // BP: paired モニタへワープ
    case block                             // BB: 何もしない
}

public enum Judgement {

    /// PX 時の判定。sourceDisplay の各辺の OS セグメントに対し、prev→current 線分との交点を探す。
    public static func judgeCrossing(
        line: LineSegment,
        sourceDisplayId: String,
        tables: WarpTables
    ) -> CrossingJudgement {
        guard let source = tables.display(sourceDisplayId) else { return .noCrossing }

        // 優先度リスト順で最初に見つかった OS セグメントを採用 (DR-0006 決定 5)
        for seg in tables.osSegments where seg.displayId == sourceDisplayId {
            guard let hit = intersectLineWithEdge(line, display: source, side: seg.side) else { continue }
            let alongLogical = seg.side.isHorizontal ? hit.x : hit.y
            guard seg.containsAlongEdgeLogical(alongLogical) else { continue }

            // userSegments に同じ (displayId, side) で along を含むものがあれば PP
            let hasUser = tables.userSegments.contains { us in
                us.displayId == sourceDisplayId
                    && us.side == seg.side
                    && us.containsAlongEdgeLogical(alongLogical)
            }
            if hasUser {
                return .pp
            } else {
                // PB: 交点上にクランプ (交点自体は source display のエッジ上、= OS がクランプする位置)
                return .pb(clampTo: hit)
            }
        }
        return .noCrossing
    }

    /// BX 時の判定。(displayId, side, along=current 座標) 位置に userSegment があれば BP、なければ BB。
    public static func judgeBlocked(
        at point: LogicalPoint,
        displayId: String,
        side: Side,
        tables: WarpTables,
        inwardInsetMillimeters: Double = 0.001
    ) -> BXOutcome {
        guard let source = tables.display(displayId) else { return .block }
        let along = side.isHorizontal ? point.x : point.y

        // 優先度リスト順で最初にヒットする userSegment を採用
        guard let userSrc = tables.userSegments.first(where: { us in
            us.displayId == displayId && us.side == side && us.containsAlongEdgeLogical(along)
        }) else {
            return .block
        }
        guard let userDst = tables.userSegment(id: userSrc.pairedSegmentId),
              let pairedDisplay = tables.display(userDst.displayId) else {
            return .block
        }

        // paired display へのワープ先を rate 写像で求める
        let raw = RateMapping.warpDestination(
            crossingPoint: point,
            sourceSegment: userSrc,
            sourceDisplay: source,
            pairedSegment: userDst,
            pairedDisplay: pairedDisplay
        )
        // 対向モニタの少し内側へずらす (V3 の get_inward_offset に相当。境界上放置で即 BX 再発するのを回避)
        // inset は物理 (mm) 単位。paired display の pose で論理 px に換算してからずらす。
        let insetLogical = physicalToLogicalInsetVector(
            side: userDst.side, insetMillimeters: inwardInsetMillimeters, pose: pairedDisplay.pose)
        return .pass(warpTo: LogicalPoint(x: raw.x + insetLogical.x, y: raw.y + insetLogical.y))
    }

    // ================================
    // 交差計算
    // ================================

    /// 線分 line が display の指定 side (エッジ) と交わる点を返す。交わらなければ nil。
    internal static func intersectLineWithEdge(_ line: LineSegment, display d: Display, side: Side) -> LogicalPoint? {
        let from = line.from
        let to = line.to
        switch side {
        case .top, .bottom:
            let y = d.edgeFixedLogicalCoord(side)
            if (from.y - y) * (to.y - y) > 0 { return nil }
            if to.y == from.y { return nil }
            let t = (y - from.y) / (to.y - from.y)
            if t < 0 || t > 1 { return nil }
            let x = from.x + t * (to.x - from.x)
            return LogicalPoint(x: x, y: y)
        case .left, .right:
            let x = d.edgeFixedLogicalCoord(side)
            if (from.x - x) * (to.x - x) > 0 { return nil }
            if to.x == from.x { return nil }
            let t = (x - from.x) / (to.x - from.x)
            if t < 0 || t > 1 { return nil }
            let y = from.y + t * (to.y - from.y)
            return LogicalPoint(x: x, y: y)
        }
    }

    /// 対向モニタ側の「辺の内向き」への物理 (mm) inset を、当該 pose で論理 px 変位に換算する。
    internal static func physicalToLogicalInsetVector(
        side: Side, insetMillimeters mm: Double, pose: DisplayPose
    ) -> (x: Double, y: Double) {
        // 内向き = paired 側の「外辺」から内側へ。y-down なので top 側の内向きは +y、bottom は -y。
        switch side {
        case .top:    return (0,   mm / pose.scaleY)   // 論理 y+ が内側 (下方向) へ
        case .bottom: return (0,  -mm / pose.scaleY)   // 論理 y- が内側 (上方向) へ
        case .left:   return ( mm / pose.scaleX, 0)
        case .right:  return (-mm / pose.scaleX, 0)
        }
    }
}
