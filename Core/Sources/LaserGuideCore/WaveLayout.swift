// WaveLayout (DR-0011 決定 2: 隣接物理レイアウト)
//
// キャリブレーション未整備の現時点では pose.translate を尊重せず (未キャリブ時は translate=0 が
// per-display 独立の mm 空間となり、モニタ間の波の連続性が壊れるため)、「論理配置の隣接関係を
// 保ったまま、物理サイズ (mm/px scale) で各モニタを接して並べる」派生レイアウトを都度構築する。
//
// 構築規則 (DR-0011 決定 2):
//   - anchor: 論理 (0,0) を containsHalfOpen する display (= primary)。無ければ
//     logicalBounds.(minY, minX) 辞書順最小。anchor の mmRect.min = (0,0)
//   - 接触判定: 論理空間で辺が接する (eps=0.5px、実機の max 側 -0.02px clamp を吸収するため
//     `Adjacency` の厳密一致より緩い) かつ直交 overlap 区間長 > 0 (角のみの接触は非接触扱い)
//   - 配置 (BFS): 接触グラフを anchor から幅優先探索。B を A の右に置く場合
//     `B.mm.minX = A.mm.maxX`、直交方向は「論理 overlap 区間の中点が mm 空間で一致する」よう
//     平行移動する。他の辺 (left/top/bottom) も対称に扱う。複数の親から到達可能な場合は
//     BFS で最初に到達した経路を採用する
//   - 非連結成分: fallback として `mmRect.min = (logical.minX*scaleX, logical.minY*scaleY)`
//     (translate=0 相当) で置く。重なりうるが Phase 1 は許容する
import Foundation

/// 1 display の波動 mm 空間での配置。
public struct WavePlacement: Equatable, Sendable {
    public let displayId: String
    public let logicalBounds: LogicalRect
    /// mm/px (display.pose.scaleX/scaleY をそのまま運ぶ)
    public let scaleX: Double
    public let scaleY: Double
    /// 波動 mm 空間でのこの display の矩形
    public let mmRect: PhysicalRect

    public init(displayId: String, logicalBounds: LogicalRect, scaleX: Double, scaleY: Double, mmRect: PhysicalRect) {
        self.displayId = displayId
        self.logicalBounds = logicalBounds
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.mmRect = mmRect
    }

    /// 論理座標の点を、この display の mmRect 基準で mm 空間の点へ写像する。
    public func toMM(_ p: LogicalPoint) -> PhysicalPoint {
        PhysicalPoint(
            x: mmRect.minX + (p.x - logicalBounds.minX) * scaleX,
            y: mmRect.minY + (p.y - logicalBounds.minY) * scaleY
        )
    }

    /// 論理座標の矩形を mm 空間の矩形へ写像する (2 隅を toMM で変換するだけで足りる。
    /// scale は正値の契約 (`DisplayPose.init` の precondition) なので順序が保たれる)。
    public func toMM(_ r: LogicalRect) -> PhysicalRect {
        let minPoint = toMM(LogicalPoint(x: r.minX, y: r.minY))
        let maxPoint = toMM(LogicalPoint(x: r.maxX, y: r.maxY))
        return PhysicalRect(minX: minPoint.x, minY: minPoint.y, maxX: maxPoint.x, maxY: maxPoint.y)
    }

    /// mm 空間の点を、この display の view-local px (= view 左上原点) へ写像する。
    /// local = (mm - mmRect.min) / scale。
    public func localPx(fromMM p: PhysicalPoint) -> LogicalPoint {
        LogicalPoint(
            x: (p.x - mmRect.minX) / scaleX,
            y: (p.y - mmRect.minY) / scaleY
        )
    }
}

public enum WaveLayout {

    /// 接触判定の許容誤差 (px)。実機で観測される max 側 -0.02px クランプ (docs/findings/
    /// 2026-07-09-macos-display-api-verification.md §4) を吸収するため 0.5px を採る
    /// (`Adjacency.detectOSPassSegments` の厳密一致 (`==`) よりあえて緩めている)。
    private static let touchEpsilon = 0.5

    /// display 集合から、隣接物理レイアウト (mm 空間配置) を構築する。
    public static func placements(displays: [Display]) -> [WavePlacement] {
        guard !displays.isEmpty else { return [] }

        // 接触グラフ: index -> [(隣接 index, 自分から見た接触辺)]
        var edges: [[(index: Int, side: Side)]] = Array(repeating: [], count: displays.count)
        for i in 0..<displays.count {
            for j in 0..<displays.count where j != i {
                if let side = touchingSide(from: displays[i].logicalBounds, to: displays[j].logicalBounds) {
                    edges[i].append((j, side))
                }
            }
        }

        let anchorIndex = selectAnchorIndex(displays)

        var mmMinByIndex: [Int: PhysicalPoint] = [anchorIndex: PhysicalPoint(x: 0, y: 0)]
        var visited: Set<Int> = [anchorIndex]
        var queue: [Int] = [anchorIndex]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            // 不変条件: BFS で queue に積まれた index は積まれる直前に mmMinByIndex へ書き込み済み
            // (anchor は初期化時、以降は visited 挿入と同時に書き込む)。nil は到達しない。
            guard let currentMMMin = mmMinByIndex[current] else {
                preconditionFailure("WaveLayout: BFS invariant violated — index \(current) has no mm placement")
            }
            for (neighborIndex, side) in edges[current] where !visited.contains(neighborIndex) {
                let childMMMin = childMMMin(
                    parent: displays[current], parentMMMin: currentMMMin,
                    child: displays[neighborIndex], parentSide: side)
                mmMinByIndex[neighborIndex] = childMMMin
                visited.insert(neighborIndex)
                queue.append(neighborIndex)
            }
        }

        // 非連結成分: translate=0 相当の fallback (DR-0011 決定 2)。
        for i in 0..<displays.count where !visited.contains(i) {
            let bounds = displays[i].logicalBounds
            let pose = displays[i].pose
            mmMinByIndex[i] = PhysicalPoint(x: bounds.minX * pose.scaleX, y: bounds.minY * pose.scaleY)
        }

        return displays.enumerated().map { i, display in
            // 不変条件: BFS (連結成分) + fallback ループ (非連結成分) で全 index を埋め終えている。
            guard let mmMin = mmMinByIndex[i] else {
                preconditionFailure("WaveLayout: display \(display.id) has no mm placement after BFS + fallback pass")
            }
            let mmRect = PhysicalRect(
                minX: mmMin.x, minY: mmMin.y,
                maxX: mmMin.x + display.logicalBounds.width * display.pose.scaleX,
                maxY: mmMin.y + display.logicalBounds.height * display.pose.scaleY
            )
            return WavePlacement(
                displayId: display.id, logicalBounds: display.logicalBounds,
                scaleX: display.pose.scaleX, scaleY: display.pose.scaleY, mmRect: mmRect)
        }
    }

    /// anchor 選択: 論理 (0,0) を containsHalfOpen する display。無ければ (minY, minX) 辞書順最小。
    private static func selectAnchorIndex(_ displays: [Display]) -> Int {
        if let index = displays.firstIndex(where: { $0.logicalBounds.containsHalfOpen(LogicalPoint(x: 0, y: 0)) }) {
            return index
        }
        var bestIndex = 0
        for i in 1..<displays.count {
            let candidate = displays[i].logicalBounds
            let best = displays[bestIndex].logicalBounds
            if (candidate.minY, candidate.minX) < (best.minY, best.minX) {
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// `a` から見て `b` がどの辺に接しているかを返す。接していなければ nil。
    /// 角のみの接触 (直交 overlap 区間長 = 0) は非接触として扱う (DR-0011 決定 2)。
    private static func touchingSide(from a: LogicalRect, to b: LogicalRect) -> Side? {
        if abs(a.maxX - b.minX) <= touchEpsilon, overlapLength(a.minY, a.maxY, b.minY, b.maxY) > 0 {
            return .right
        }
        if abs(a.minX - b.maxX) <= touchEpsilon, overlapLength(a.minY, a.maxY, b.minY, b.maxY) > 0 {
            return .left
        }
        if abs(a.maxY - b.minY) <= touchEpsilon, overlapLength(a.minX, a.maxX, b.minX, b.maxX) > 0 {
            return .bottom
        }
        if abs(a.minY - b.maxY) <= touchEpsilon, overlapLength(a.minX, a.maxX, b.minX, b.maxX) > 0 {
            return .top
        }
        return nil
    }

    private static func overlapLength(_ aMin: Double, _ aMax: Double, _ bMin: Double, _ bMax: Double) -> Double {
        min(aMax, bMax) - max(aMin, bMin)
    }

    /// 論理 overlap 区間の中点 (直交軸)。
    private static func overlapMidpoint(_ aMin: Double, _ aMax: Double, _ bMin: Double, _ bMax: Double) -> Double {
        (max(aMin, bMin) + min(aMax, bMax)) / 2
    }

    /// 親 display の mm 空間写像 (mmMin 起点) で、論理 y 座標を mm y 座標へ変換する。
    private static func mmY(_ display: Display, mmMin: PhysicalPoint, atLogicalY y: Double) -> Double {
        mmMin.y + (y - display.logicalBounds.minY) * display.pose.scaleY
    }

    /// 親 display の mm 空間写像 (mmMin 起点) で、論理 x 座標を mm x 座標へ変換する。
    private static func mmX(_ display: Display, mmMin: PhysicalPoint, atLogicalX x: Double) -> Double {
        mmMin.x + (x - display.logicalBounds.minX) * display.pose.scaleX
    }

    /// 接触辺 `parentSide` (親から見た接触辺) を使って、子 display の mmRect.min を決定する。
    /// 固定軸 (接触辺に垂直な方向) は親の mmRect の対応する辺にそのまま接し、直交軸 (接触辺に
    /// 沿う方向) は論理 overlap 区間の中点が親・子の mm 写像で一致するよう平行移動する
    /// (DR-0011 決定 2 の「B.mm.minX = A.mm.maxX、直交方向は中点一致」を 4 辺対称に適用)。
    private static func childMMMin(
        parent: Display, parentMMMin: PhysicalPoint, child: Display, parentSide: Side
    ) -> PhysicalPoint {
        switch parentSide {
        case .right:
            let childMinX = mmX(parent, mmMin: parentMMMin, atLogicalX: parent.logicalBounds.maxX)
            let yc = overlapMidpoint(
                parent.logicalBounds.minY, parent.logicalBounds.maxY,
                child.logicalBounds.minY, child.logicalBounds.maxY)
            let targetMMY = mmY(parent, mmMin: parentMMMin, atLogicalY: yc)
            let childMinY = targetMMY - (yc - child.logicalBounds.minY) * child.pose.scaleY
            return PhysicalPoint(x: childMinX, y: childMinY)

        case .left:
            let childMaxX = mmX(parent, mmMin: parentMMMin, atLogicalX: parent.logicalBounds.minX)
            let childMinX = childMaxX - child.logicalBounds.width * child.pose.scaleX
            let yc = overlapMidpoint(
                parent.logicalBounds.minY, parent.logicalBounds.maxY,
                child.logicalBounds.minY, child.logicalBounds.maxY)
            let targetMMY = mmY(parent, mmMin: parentMMMin, atLogicalY: yc)
            let childMinY = targetMMY - (yc - child.logicalBounds.minY) * child.pose.scaleY
            return PhysicalPoint(x: childMinX, y: childMinY)

        case .bottom:
            let childMinY = mmY(parent, mmMin: parentMMMin, atLogicalY: parent.logicalBounds.maxY)
            let xc = overlapMidpoint(
                parent.logicalBounds.minX, parent.logicalBounds.maxX,
                child.logicalBounds.minX, child.logicalBounds.maxX)
            let targetMMX = mmX(parent, mmMin: parentMMMin, atLogicalX: xc)
            let childMinX = targetMMX - (xc - child.logicalBounds.minX) * child.pose.scaleX
            return PhysicalPoint(x: childMinX, y: childMinY)

        case .top:
            let childMaxY = mmY(parent, mmMin: parentMMMin, atLogicalY: parent.logicalBounds.minY)
            let childMinY = childMaxY - child.logicalBounds.height * child.pose.scaleY
            let xc = overlapMidpoint(
                parent.logicalBounds.minX, parent.logicalBounds.maxX,
                child.logicalBounds.minX, child.logicalBounds.maxX)
            let targetMMX = mmX(parent, mmMin: parentMMMin, atLogicalX: xc)
            let childMinX = targetMMX - (xc - child.logicalBounds.minX) * child.pose.scaleX
            return PhysicalPoint(x: childMinX, y: childMinY)
        }
    }
}
