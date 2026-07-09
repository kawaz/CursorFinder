// OS 隣接検出 (V3 moonbit/src/init.mbt::detect_touching_edges の y-down 版再導出)
//
// V3 版は y-up (NSScreen) 前提で書かれていたため、そのままの写経は Top/Bottom 反転バグを
// 再発させる (2026-07 レビューで Critical 判定)。値を写さず、意味論だけ再導出する。
//
// y-down (DR-0005) では:
//   - A.right (maxX) が B.left (minX) と接触: A.maxX == B.minX、y 範囲が重なる
//   - A.left  (minX) が B.right(maxX) と接触
//   - A.bottom(maxY) が B.top  (minY) と接触: A.maxY == B.minY、x 範囲が重なる (A が上、B が下)
//   - A.top   (minY) が B.bottom(maxY) と接触
//
// 生成される PassSegment ペアは "os-<aid>-<bid>-<side>" 命名で id を作り、pairedSegmentId を
// 相互参照させる。along-edge 論理レンジは 2 モニタの当該辺で共通する区間 [max(start), min(end)] を使う。
import Foundation

public enum Adjacency {
    /// display 集合から OS 隣接 (物理接触) の PassSegment ペア列を生成する。
    /// 各接触につき 2 個のセグメント (a→b と b→a) を返す。順序はモニタ id 昇順→side 順で決定的。
    public static func detectOSPassSegments(_ displays: [Display]) -> [PassSegment] {
        var out: [PassSegment] = []
        // 決定的な列挙のため id ソート済みで走る
        let sorted = displays.sorted { $0.id < $1.id }
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i]
                let b = sorted[j]
                appendPairIfTouching(a: a, b: b, into: &out)
            }
        }
        return out
    }

    private static func appendPairIfTouching(a: Display, b: Display, into out: inout [PassSegment]) {
        let ra = a.logicalBounds
        let rb = b.logicalBounds

        // a.right が b.left と接触 (vertical edge, along-edge = y)
        if ra.maxX == rb.minX {
            let ys = max(ra.minY, rb.minY)
            let ye = min(ra.maxY, rb.maxY)
            if ys < ye {
                pushPair(aDisplay: a, aSide: .right, bDisplay: b, bSide: .left,
                         alongStart: ys, alongEnd: ye, into: &out)
                return
            }
        }
        // a.left が b.right と接触
        if ra.minX == rb.maxX {
            let ys = max(ra.minY, rb.minY)
            let ye = min(ra.maxY, rb.maxY)
            if ys < ye {
                pushPair(aDisplay: a, aSide: .left, bDisplay: b, bSide: .right,
                         alongStart: ys, alongEnd: ye, into: &out)
                return
            }
        }
        // a.bottom (maxY, y-down で下) が b.top (minY, 上) と接触 → A が上・B が下
        if ra.maxY == rb.minY {
            let xs = max(ra.minX, rb.minX)
            let xe = min(ra.maxX, rb.maxX)
            if xs < xe {
                pushPair(aDisplay: a, aSide: .bottom, bDisplay: b, bSide: .top,
                         alongStart: xs, alongEnd: xe, into: &out)
                return
            }
        }
        // a.top が b.bottom と接触 → A が下・B が上
        if ra.minY == rb.maxY {
            let xs = max(ra.minX, rb.minX)
            let xe = min(ra.maxX, rb.maxX)
            if xs < xe {
                pushPair(aDisplay: a, aSide: .top, bDisplay: b, bSide: .bottom,
                         alongStart: xs, alongEnd: xe, into: &out)
                return
            }
        }
    }

    private static func pushPair(
        aDisplay: Display, aSide: Side,
        bDisplay: Display, bSide: Side,
        alongStart: Double, alongEnd: Double,
        into out: inout [PassSegment]
    ) {
        let aid = "os-\(aDisplay.id)-\(bDisplay.id)-\(aSide.rawValue)"
        let bid = "os-\(bDisplay.id)-\(aDisplay.id)-\(bSide.rawValue)"
        out.append(PassSegment(
            id: aid, displayId: aDisplay.id, side: aSide,
            logicalStart: alongStart, logicalEnd: alongEnd, pairedSegmentId: bid
        ))
        out.append(PassSegment(
            id: bid, displayId: bDisplay.id, side: bSide,
            logicalStart: alongStart, logicalEnd: alongEnd, pairedSegmentId: aid
        ))
    }
}
