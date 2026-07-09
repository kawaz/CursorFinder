// rate 写像 (DR-0006 決定 2 — ユーザセグメント専用の意味論)
//
// **この写像は「ユーザセグメント (仮想接続)」専用**。物理的に隣接しない 2 辺を、長さが違っても
// 意図的に比例対応させたい場面 (例: 狭いサブディスプレイの全幅を広いメインディスプレイの一部区間に
// 対応させる) のための意味論であり、「物理座標が一致する」ことは要求しない。
//
// 交点のセグメント内位置を「物理 (mm) 長」で正規化し、対向セグメントの物理 rate (0...1) に写像して
// 座標化する。論理 (px) 長ではなく物理長で正規化するのは、混合 DPI (retina 内蔵 + 外部) のセグメント
// 同士でも「両端点間の何 % の位置か」が一致するようにするため (px 長で正規化すると異なる DPI 間で
// 対応位置が歪む)。
//
// 2026-07-10 コアレビュー C-1: 当初の設計は「OS 自動ペア (物理隣接) の写像もこの rate 正規化を使う」
// だったが、物理的に隣接する 2 セグメント間でレーザー直線の継ぎ目連続性と rate 写像の着地点が一致しない
// 反例 (異なる DPI の物理隣接ペアで 50%→50% が物理座標としては不連続) が見つかったため、OS 自動ペア
// (物理隣接) 用の写像は `PhysicalProjection` に分離した。両者の使い分けは DR-0006 決定 2 を参照。
//
// 手順:
//   1. 交点の along-edge 論理値を取り、pose で物理 along-edge 値へ変換
//   2. rate = (crossPhys - startPhys) / (endPhys - startPhys)
//   3. paired の along 物理値 = pairedStartPhys + rate * (pairedEndPhys - pairedStartPhys)
//   4. paired 物理点を構築し、paired display の pose で論理へ逆変換
//   5. 着地点を pairedDisplay.logicalBounds 内へクランプする (m-3。半開区間規約下で max 側ちょうど
//      だと隣のモニタ所属に化けてしまうため、max 側は内側へわずかに引き込む)
//
// pose がスケール軸別なので、辺 (論理で軸に平行) は物理でも軸に平行に保たれる = 「固定軸」の
// 物理値は along によらず不変であることを利用してよい。
import Foundation

public enum RateMapping {

    /// 着地点を display の論理境界内へクランプする際、max 側に適用する内向きインセット (論理 px)。
    /// 半開区間規約 ([min, max)) の下では境界値ちょうどは隣接モニタの所属になるため、0 だと
    /// クランプした直後の着地点が別モニタ所属と判定されてしまう。m-3 / C-2 で共有する値。
    public static let boundaryInwardInsetLogicalPixels: Double = 0.25

    /// 論理点 p を display の論理境界内へクランプする (半開区間規約: min 側はちょうど可、max 側は
    /// `boundaryInwardInsetLogicalPixels` だけ内側へ)。
    internal static func clampInsideLogicalBoundsHalfOpen(_ p: LogicalPoint, bounds: LogicalRect) -> LogicalPoint {
        let inset = boundaryInwardInsetLogicalPixels
        // モニタ幅がインセットより狭い退化ケースでも中心へ潰れるだけで済むよう min を挟む。
        let maxX = max(bounds.minX, bounds.maxX - inset)
        let maxY = max(bounds.minY, bounds.maxY - inset)
        return LogicalPoint(
            x: min(max(p.x, bounds.minX), maxX),
            y: min(max(p.y, bounds.minY), maxY)
        )
    }

    /// エッジ上の交点 (論理、source display 空間) からワープ先論理点 (paired display 空間) を求める。
    /// **ユーザセグメント (仮想接続) 専用**。OS 自動ペア (物理隣接) には `PhysicalProjection` を使う。
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

        let landed = pairedDisplay.pose.toLogical(pPhysical)
        return clampInsideLogicalBoundsHalfOpen(landed, bounds: pairedDisplay.logicalBounds)
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
