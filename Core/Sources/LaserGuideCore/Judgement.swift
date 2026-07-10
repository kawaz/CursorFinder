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
    case block                             // BB: 何もしない (userSegment が無い、または OS が通す辺での誤検出)
    /// userSegment はあるが pairedSegmentId が指す先 (userSegment 自体、または対応 display) が
    /// 存在しない「参照切れ」。挙動は block と同じ (ワープしない) だが、原因が違うことを診断情報として
    /// 区別する (DR-0007 決定 7 の inactive 可視化用、m-5)。
    case blockDanglingReference(pairedSegmentId: String)
}

public enum Judgement {

    /// PX 時の判定。sourceDisplay の各辺の OS セグメントに対し、prev→current 線分との交点を探す。
    /// カド越しの斜め移動では複数辺と交わりうる。id 順 (= osSegments の配列順) ではなく、移動線分
    /// パラメータ t が最小の交点 (= line.from に最も近い、実際に最初に到達する辺) を採用する
    /// (m-2 minor: 配列順は生成順の副産物であって「最初に触れる辺」の意味を持たないため)。
    public static func judgeCrossing(
        line: LineSegment,
        sourceDisplayId: String,
        tables: WarpTables
    ) -> CrossingJudgement {
        guard let source = tables.display(sourceDisplayId) else { return .noCrossing }

        // 3-要素 tuple は SwiftLint の large_tuple 対象になるので struct として持つ
        // (意味論的にも「勝者候補」= 単一の集約値、tuple より struct が正)。
        struct Candidate { let t: Double; let hit: LogicalPoint; let seg: PassSegment }
        var best: Candidate?
        for seg in tables.osSegments where seg.displayId == sourceDisplayId {
            guard let (hit, t) = intersectLineWithEdgeParam(line, display: source, side: seg.side) else { continue }
            let alongLogical = seg.side.isHorizontal ? hit.x : hit.y
            guard seg.containsAlongEdgeLogical(alongLogical) else { continue }
            if let current = best, t >= current.t { continue }
            best = Candidate(t: t, hit: hit, seg: seg)
        }
        guard let winner = best else { return .noCrossing }

        let alongLogical = winner.seg.side.isHorizontal ? winner.hit.x : winner.hit.y
        // userSegments に同じ (displayId, side) で along を含むものがあれば PP
        let hasUser = tables.userSegments.contains { us in
            us.displayId == sourceDisplayId
                && us.side == winner.seg.side
                && us.containsAlongEdgeLogical(alongLogical)
        }
        if hasUser {
            return .pp
        } else {
            // PB: 半開区間規約 ([min,max)) の下では交点座標そのもの (= source display の
            // maxX/maxY 側境界値ちょうど) は隣接モニタ (paired display) の所属になってしまう
            // (2026-07-10 コアレビュー C-2)。source display 内側へ 0.25 論理 px 相当だけ引き込んだ
            // 座標にクランプする。0.25 は Trigger.defaultEdgeEpsilon (0.1) を確実に上回り、
            // 次の判定サイクルで BX 判定の ε 近傍に戻らない値として選んだ (m-3 と同じ定数を共有)。
            return .pb(clampTo: inwardClampedPoint(winner.hit, side: winner.seg.side, display: source))
        }
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

        // M-1: OS がこの (displayId, side, along) を通す辺として持っているなら、そもそも BX として
        // ここへ来たこと自体が誤検出 (エッジ ε 近傍の丸め等)。ユーザ判定を行わず block で確定する。
        let osPassesHere = tables.osSegments.contains { os in
            os.displayId == displayId && os.side == side && os.containsAlongEdgeLogical(along)
        }
        guard !osPassesHere else { return .block }

        // 優先度リスト順で最初にヒットする userSegment を採用
        guard let userSrc = tables.userSegments.first(where: { us in
            us.displayId == displayId && us.side == side && us.containsAlongEdgeLogical(along)
        }) else {
            return .block
        }
        guard let userDst = tables.userSegment(id: userSrc.pairedSegmentId),
              let pairedDisplay = tables.display(userDst.displayId) else {
            // m-5: userSegment 自体はあるが paired 参照が解決できない (削除済み segment / 消えた
            // display 等)。ワープしない点は BB と同じだが、原因を診断情報として区別する。
            return .blockDanglingReference(pairedSegmentId: userSrc.pairedSegmentId)
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

    /// M-2: カドで複数辺が BX 候補になる場合、優先度順に試し、先頭が block/danglingReference なら
    /// 次候補を試す (2 段評価)。全候補が非 pass なら先頭候補の結果を返す (診断情報を保つため
    /// 一律 .block に潰さない)。sides は Trigger.classify が返す優先度順の候補列 (非空)。
    public static func judgeBlockedWithFallback(
        at point: LogicalPoint,
        displayId: String,
        sides: [Side],
        tables: WarpTables,
        inwardInsetMillimeters: Double = 0.001
    ) -> BXOutcome {
        precondition(!sides.isEmpty, "judgeBlockedWithFallback: sides は少なくとも 1 件必要")
        var firstOutcome: BXOutcome?
        for side in sides {
            let outcome = judgeBlocked(
                at: point, displayId: displayId, side: side, tables: tables,
                inwardInsetMillimeters: inwardInsetMillimeters)
            if firstOutcome == nil { firstOutcome = outcome }
            if case .pass = outcome { return outcome }
        }
        return firstOutcome ?? .block
    }

    // ================================
    // 交差計算
    // ================================

    /// 線分 line が display の指定 side (エッジ) と交わる点と、その線分パラメータ t (0...1、
    /// line.from に近いほど小さい) を返す。交わらなければ nil。
    internal static func intersectLineWithEdgeParam(
        _ line: LineSegment, display d: Display, side: Side
    ) -> (point: LogicalPoint, t: Double)? {
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
            return (LogicalPoint(x: x, y: y), t)
        case .left, .right:
            let x = d.edgeFixedLogicalCoord(side)
            if (from.x - x) * (to.x - x) > 0 { return nil }
            if to.x == from.x { return nil }
            let t = (x - from.x) / (to.x - from.x)
            if t < 0 || t > 1 { return nil }
            let y = from.y + t * (to.y - from.y)
            return (LogicalPoint(x: x, y: y), t)
        }
    }

    /// 点 p を display の指定 side の内側へ、`RateMapping.boundaryInwardInsetLogicalPixels`
    /// (0.25 論理 px) 相当だけ引き込んだ座標にする (C-2)。0.25 論理 px を display の pose で
    /// 物理 mm に換算してから `physicalToLogicalInsetVector` に渡すことで、m-3 のクランプ実装と
    /// 同じ経路 (物理 mm 単位の inset → pose で論理へ戻す) を共有する。
    internal static func inwardClampedPoint(_ p: LogicalPoint, side: Side, display: Display) -> LogicalPoint {
        let scaleForFixedAxis = side.isHorizontal ? display.pose.scaleY : display.pose.scaleX
        let insetMillimeters = RateMapping.boundaryInwardInsetLogicalPixels * scaleForFixedAxis
        let inset = physicalToLogicalInsetVector(side: side, insetMillimeters: insetMillimeters, pose: display.pose)
        return LogicalPoint(x: p.x + inset.x, y: p.y + inset.y)
    }

    /// 対向モニタ側の「辺の内向き」への物理 (mm) inset を、当該 pose で論理 px 変位に換算する。
    internal static func physicalToLogicalInsetVector(
        side: Side, insetMillimeters mm: Double, pose: DisplayPose
    ) -> (x: Double, y: Double) {
        // 内向き = paired 側の「外辺」から内側へ。y-down なので top 側の内向きは +y、bottom は -y。
        switch side {
        case .top:    return (0, mm / pose.scaleY)     // 論理 y+ が内側 (下方向) へ
        case .bottom: return (0, -mm / pose.scaleY)    // 論理 y- が内側 (上方向) へ
        case .left:   return (mm / pose.scaleX, 0)
        case .right:  return (-mm / pose.scaleX, 0)
        }
    }
}
