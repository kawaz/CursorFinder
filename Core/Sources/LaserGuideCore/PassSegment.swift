// PassSegment (DR-0006: v2 の PassSegment ペア方式)
//
// - displayId + side + along-edge の論理レンジ [start, end) で辺上の連続区間を表す
// - pairedSegmentId は対向モニタ側の対応セグメント ID
// - EdgeType (PP/PB/BP/BB) は「osPassSegments と userSegments の集合差分」で導出する派生値。
//   保存されるのは 2 リストのセグメント集合だけ (DR-0006 決定 1)
//
// start > end も許容 (捻れ対応)。判定側は正規化して扱う。
import Foundation

public struct PassSegment: Equatable, Hashable, Sendable {
    public let id: String
    public let displayId: String
    public let side: Side
    public let logicalStart: Double
    public let logicalEnd: Double
    public let pairedSegmentId: String

    public init(
        id: String,
        displayId: String,
        side: Side,
        logicalStart: Double,
        logicalEnd: Double,
        pairedSegmentId: String
    ) {
        self.id = id
        self.displayId = displayId
        self.side = side
        self.logicalStart = logicalStart
        self.logicalEnd = logicalEnd
        self.pairedSegmentId = pairedSegmentId
    }

    /// along-edge の論理座標が本セグメントの範囲内か。start/end の並び順に依存しない。
    public func containsAlongEdgeLogical(_ coord: Double) -> Bool {
        let lo = min(logicalStart, logicalEnd)
        let hi = max(logicalStart, logicalEnd)
        return coord >= lo && coord <= hi
    }
}
