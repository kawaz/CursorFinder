// WaveGeometry (DR-0011 決定 3: 波動の幾何)
//
// 波 = 震源矩形 (フォーカスウィンドウの mm 写像) を radius だけ外側へ膨張した角丸矩形リング
// (cornerRadius = radius、= 矩形からの等距離線)。帯幅 bandMM、進行 p∈[0,1] で
//   radius  = p * (maxDistanceMM + bandMM)
//   opacity = initialOpacity * (1 - p)
// maxDistanceMM は全 display mmRect の 4 隅と震源矩形の点-矩形距離の最大値 (= 波が最遠隅に
// 到達しきってから消える)。角丸矩形リングの描画自体は App 層の責務、ここでは半径・不透明度・
// 距離計算の純粋幾何のみを提供する。
import Foundation

public enum WaveGeometry {

    /// 点-矩形距離。点が矩形内部 (境界含む) なら 0。矩形の外側では最近接点までのユークリッド距離。
    public static func distance(from rect: PhysicalRect, to p: PhysicalPoint) -> Double {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 全 placement の mmRect 4 隅から震源矩形への距離の最大値。波が全モニタの最遠隅に到達しきる
    /// までの距離を表す (DR-0011 決定 3)。placements が空なら 0 (波は最初から到達済み扱い)。
    public static func maxDistanceMM(epicenter: PhysicalRect, placements: [WavePlacement]) -> Double {
        var result = 0.0
        for placement in placements {
            let corners = [
                PhysicalPoint(x: placement.mmRect.minX, y: placement.mmRect.minY),
                PhysicalPoint(x: placement.mmRect.maxX, y: placement.mmRect.minY),
                PhysicalPoint(x: placement.mmRect.minX, y: placement.mmRect.maxY),
                PhysicalPoint(x: placement.mmRect.maxX, y: placement.mmRect.maxY)
            ]
            for corner in corners {
                result = max(result, distance(from: epicenter, to: corner))
            }
        }
        return result
    }

    /// 進行度 p (呼び出し側が [0,1] に収めて渡す想定) → 波リング外縁半径。
    /// Design rationale: ここでは p をクランプしない (`opacity` はクランプする、下記参照)。
    /// p が 1 を超えて呼ばれても `opacity` が 0 に落ちるため、描画層は opacity=0 判定だけで
    /// 半径の超過を無視できる — 見えない波の半径を律儀にクランプする意味がない (DR-0011 決定 3)。
    public static func radiusMM(progress: Double, maxDistanceMM: Double, bandMM: Double) -> Double {
        progress * (maxDistanceMM + bandMM)
    }

    /// 進行度 p → 波の不透明度。p は [0,1] にクランプしてから使う (呼び出し側の丸め誤差・
    /// タイマーのオーバーシュートで p がわずかに範囲外になっても負の不透明度や 1 超過を防ぐ)。
    public static func opacity(progress: Double, initialOpacity: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return initialOpacity * (1 - clamped)
    }
}
