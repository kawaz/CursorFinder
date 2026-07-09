// rate 写像 (DR-0006 決定 2)
//
// 交点のセグメント内位置を「物理 (mm) 長」で正規化し、対向セグメントの物理 rate に写像して座標化する。
// 論理 (px) 長ではなく物理長を使うことで、混合 DPI (retina 内蔵 + 外部) を跨いだ時にレーザーの
// 直線が物理空間で繋がる (DR-0006 決定 2 の整合条件)。
//
// 手順:
//   1. 交点の along-edge 論理値を取り、pose で物理 along-edge 値へ変換
//   2. rate = (crossPhys - startPhys) / (endPhys - startPhys)
//   3. paired の along 物理値 = pairedStartPhys + rate * (pairedEndPhys - pairedStartPhys)
//   4. paired 物理点を構築し、paired display の pose で論理へ逆変換
//
// pose がスケール軸別なので、辺 (論理で軸に平行) は物理でも軸に平行に保たれる = 「固定軸」の
// 物理値は along によらず不変であることを利用してよい。
import Foundation

public enum RateMapping {

    /// エッジ上の交点 (論理、source display 空間) からワープ先論理点 (paired display 空間) を求める。
    public static func warpDestination(
        crossingPoint: LogicalPoint,
        sourceSegment: PassSegment,
        sourceDisplay: Display,
        pairedSegment: PassSegment,
        pairedDisplay: Display
    ) -> LogicalPoint {
        precondition(sourceSegment.displayId == sourceDisplay.id)
        precondition(pairedSegment.displayId == pairedDisplay.id)

        // source 側 along 物理値
        let srcCrossAlong = alongPhysical(
            side: sourceSegment.side, display: sourceDisplay, alongLogical: alongLogical(crossingPoint, sourceSegment.side))
        let srcStartAlong = alongPhysical(
            side: sourceSegment.side, display: sourceDisplay, alongLogical: sourceSegment.logicalStart)
        let srcEndAlong = alongPhysical(
            side: sourceSegment.side, display: sourceDisplay, alongLogical: sourceSegment.logicalEnd)

        // 物理長ゼロの縮退 (通常はゼロ長セグメントは隣接検出で除外されるが、安全側で 0 を返す)
        let srcSpan = srcEndAlong - srcStartAlong
        let rate: Double
        if srcSpan == 0 {
            rate = 0
        } else {
            rate = (srcCrossAlong - srcStartAlong) / srcSpan
        }

        // paired 側 along 物理値
        let pStartAlong = alongPhysical(
            side: pairedSegment.side, display: pairedDisplay, alongLogical: pairedSegment.logicalStart)
        let pEndAlong = alongPhysical(
            side: pairedSegment.side, display: pairedDisplay, alongLogical: pairedSegment.logicalEnd)
        let pCrossAlong = pStartAlong + rate * (pEndAlong - pStartAlong)

        // paired 側「固定軸」の物理値 (along によらず一定)
        let pFixedAlongLogical = pairedSegment.logicalStart
        let pFixedPointLogical = pointOnEdgeLogical(
            side: pairedSegment.side, display: pairedDisplay, along: pFixedAlongLogical)
        let pFixedPhysical = pairedDisplay.pose.toPhysical(pFixedPointLogical)

        // 完全な物理点を構成
        let pPhysical: PhysicalPoint
        switch pairedSegment.side {
        case .top, .bottom:
            pPhysical = PhysicalPoint(x: pCrossAlong, y: pFixedPhysical.y)
        case .left, .right:
            pPhysical = PhysicalPoint(x: pFixedPhysical.x, y: pCrossAlong)
        }

        return pairedDisplay.pose.toLogical(pPhysical)
    }

    // ================================
    // internal 補助
    // ================================

    /// along-edge の論理値を取り出す (top/bottom → x、left/right → y)
    internal static func alongLogical(_ p: LogicalPoint, _ side: Side) -> Double {
        side.isHorizontal ? p.x : p.y
    }

    /// display の指定 side 上で、along-edge 論理値から along-edge 物理値を得る
    internal static func alongPhysical(side: Side, display: Display, alongLogical: Double) -> Double {
        let pt = pointOnEdgeLogical(side: side, display: display, along: alongLogical)
        let ph = display.pose.toPhysical(pt)
        return side.isHorizontal ? ph.x : ph.y
    }

    /// display の指定 side 上の点を、along-edge 論理値から構築する
    internal static func pointOnEdgeLogical(side: Side, display: Display, along: Double) -> LogicalPoint {
        switch side {
        case .top:    return LogicalPoint(x: along, y: display.logicalBounds.minY)
        case .bottom: return LogicalPoint(x: along, y: display.logicalBounds.maxY)
        case .left:   return LogicalPoint(x: display.logicalBounds.minX, y: along)
        case .right:  return LogicalPoint(x: display.logicalBounds.maxX, y: along)
        }
    }
}
