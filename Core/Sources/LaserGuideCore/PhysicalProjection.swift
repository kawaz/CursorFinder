// 物理投影 (DR-0006 決定 2 — OS 自動ペア (物理隣接) 専用の写像。2026-07-10 コアレビュー C-1 で新設)
//
// **この写像は「OS 自動ペア (物理隣接セグメント)」専用**。物理的に接触している 2 辺の間では、
// レーザーの描画直線が継ぎ目で連続に繋がり、かつワープ着地点もその継ぎ目の物理座標と一致することが
// 要求される (pose が継ぎ目で整合していれば厳密一致)。`RateMapping.warpDestination` の rate 正規化
// (= 「対向セグメントの何 % の位置か」) では、両セグメントの物理長が異なる限りこの一致条件を満たせない
// (反例: A 右辺 [0,270mm] と B 左辺 [0,540mm] が同じ物理座標で接触するとき、A 側の物理 50% 点は
// B 側の物理 50% 点と一致しない = 直線が段付きになる)。
//
// 物理投影は rate を経由せず、交点の物理 along 座標をそのまま対向セグメントの物理 along 座標として
// 使う (範囲外は対向セグメントの物理端へクランプ)。
//
// 手順:
//   1. 交点の along-edge 論理値を取り、source display の pose で物理 along-edge 値へ変換
//   2. その物理値を、paired セグメントの物理 along レンジ [min, max] にクランプする
//      (継ぎ目の共通区間は隣接検出 (Adjacency) で揃えているため通常は範囲内に収まるが、
//      浮動小数誤差やカド越しの斜め交差では境界をわずかに超えうるため安全側でクランプする)
//   3. クランプ後の物理 along 値を使って paired 側の物理点を構築し、論理へ逆変換する
//   4. 着地点を pairedDisplay.logicalBounds 内へクランプする (m-3、RateMapping と同じ規約)
import Foundation

public enum PhysicalProjection {

    /// エッジ上の交点 (論理、source display 空間) を、対向セグメントの物理 along 座標へ射影し、
    /// paired display 空間の論理点として返す。OS 自動ペア (物理隣接) 専用、ユーザセグメントには
    /// `RateMapping.warpDestination` を使う。
    public static func project(
        crossingPoint: LogicalPoint,
        sourceSegment: PassSegment,
        sourceDisplay: Display,
        pairedSegment: PassSegment,
        pairedDisplay: Display
    ) -> LogicalPoint {
        precondition(sourceSegment.displayId == sourceDisplay.id)
        precondition(pairedSegment.displayId == pairedDisplay.id)

        let srcCrossAlong = RateMapping.alongPhysical(
            side: sourceSegment.side, display: sourceDisplay,
            alongLogical: RateMapping.alongLogical(crossingPoint, sourceSegment.side))

        let pStartAlong = RateMapping.alongPhysical(
            side: pairedSegment.side, display: pairedDisplay, alongLogical: pairedSegment.logicalStart)
        let pEndAlong = RateMapping.alongPhysical(
            side: pairedSegment.side, display: pairedDisplay, alongLogical: pairedSegment.logicalEnd)

        // 対向セグメントの物理 along レンジへクランプ (start > end の捻れも許容するため min/max で正規化)。
        let lo = min(pStartAlong, pEndAlong)
        let hi = max(pStartAlong, pEndAlong)
        let pCrossAlong = min(max(srcCrossAlong, lo), hi)

        // paired 側「固定軸」の物理値 (along によらず一定、RateMapping と同じ導出)
        let pFixedAlongLogical = pairedSegment.logicalStart
        let pFixedPointLogical = RateMapping.pointOnEdgeLogical(
            side: pairedSegment.side, display: pairedDisplay, along: pFixedAlongLogical)
        let pFixedPhysical = pairedDisplay.pose.toPhysical(pFixedPointLogical)

        let pPhysical: PhysicalPoint
        switch pairedSegment.side {
        case .top, .bottom:
            pPhysical = PhysicalPoint(x: pCrossAlong, y: pFixedPhysical.y)
        case .left, .right:
            pPhysical = PhysicalPoint(x: pFixedPhysical.x, y: pCrossAlong)
        }

        let landed = pairedDisplay.pose.toLogical(pPhysical)
        return RateMapping.clampInsideLogicalBoundsHalfOpen(landed, bounds: pairedDisplay.logicalBounds)
    }
}
