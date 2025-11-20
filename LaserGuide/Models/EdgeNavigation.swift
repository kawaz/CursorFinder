// EdgeNavigation.swift
import Foundation

/// エッジの辺（上下左右）
enum EdgeSide: String, Codable, CaseIterable {
    case top
    case bottom
    case left
    case right
}

/// Pass可能なセグメント
struct PassSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let start: Double       // 0.0〜1.0
    let end: Double         // 0.0〜1.0, start <= end（空セグメント許可）
    let pairedSegmentId: UUID
    
    init(id: UUID = UUID(), start: Double, end: Double, pairedSegmentId: UUID) {
        self.id = id
        self.start = start
        self.end = end
        self.pairedSegmentId = pairedSegmentId
    }
    
    /// 空セグメント（ワープポイント）かどうか
    var isEmpty: Bool {
        start == end
    }
    
    /// 指定位置を含むか（半開区間 [start, end)）
    func contains(_ position: Double) -> Bool {
        position >= start && position < end
    }
    
    /// 他のセグメントと重複するか
    func overlaps(_ other: PassSegment) -> Bool {
        // 空セグメント同士は重複しない
        if isEmpty || other.isEmpty {
            return false
        }
        // 範囲の重複チェック
        return start < other.end && other.start < end
    }
    
    /// バリデーション
    func validate() -> Bool {
        guard start >= 0.0 && start <= 1.0 else { return false }
        guard end >= 0.0 && end <= 1.0 else { return false }
        guard start <= end else { return false }
        return true
    }
}

/// ディスプレイのエッジ
struct DisplayEdge: Identifiable, Codable {
    let id: UUID
    let displayId: UUID
    let side: EdgeSide
    
    // PassSegmentのみ保存、それ以外は自動的にBlock
    // ソート済み、交差禁止、0.0〜1.0を必ずしも埋めない
    var passSegments: [PassSegment]
    
    init(id: UUID = UUID(), displayId: UUID, side: EdgeSide, passSegments: [PassSegment] = []) {
        self.id = id
        self.displayId = displayId
        self.side = side
        self.passSegments = passSegments
    }
    
    /// 指定位置のPassSegmentを取得
    func segment(at position: Double) -> PassSegment? {
        passSegments.first(where: { $0.contains(position) })
    }
    
    /// 指定位置が通過可能か
    func isPassable(at position: Double) -> Bool {
        segment(at: position) != nil
    }
    
    /// IDでセグメントを検索
    func segment(withId id: UUID) -> PassSegment? {
        passSegments.first(where: { $0.id == id })
    }
    
    /// バリデーション
    func validate() -> Bool {
        // 各セグメントが有効
        guard passSegments.allSatisfy({ $0.validate() }) else {
            return false
        }
        
        // セグメント同士が重複しない
        for i in 0..<passSegments.count {
            for j in (i+1)..<passSegments.count {
                if passSegments[i].overlaps(passSegments[j]) {
                    return false
                }
            }
        }
        
        return true
    }
}

/// エッジナビゲーションマップ
struct EdgeNavigationMap: Codable {
    var edges: [DisplayEdge]
    
    init(edges: [DisplayEdge] = []) {
        self.edges = edges
    }
    
    /// ディスプレイIDとサイドでエッジを検索
    func edge(displayId: UUID, side: EdgeSide) -> DisplayEdge? {
        edges.first(where: { $0.displayId == displayId && $0.side == side })
    }
    
    /// セグメントIDで検索
    func segment(withId id: UUID) -> (edge: DisplayEdge, segment: PassSegment)? {
        for edge in edges {
            if let segment = edge.segment(withId: id) {
                return (edge, segment)
            }
        }
        return nil
    }
    
    /// 越境処理
    /// - Parameters:
    ///   - position: 現在位置（0.0〜1.0）
    ///   - displayId: ディスプレイID
    ///   - side: エッジの辺
    /// - Returns: 越境先の情報（エッジ、位置）、またはnil（Block）
    func handleCrossing(
        at position: Double,
        displayId: UUID,
        side: EdgeSide
    ) -> (edge: DisplayEdge, position: Double)? {
        // 1. 該当するエッジを取得
        guard let edge = self.edge(displayId: displayId, side: side) else {
            return nil  // エッジ定義なし → Block
        }
        
        // 2. PassSegmentを探す
        guard let segment = edge.segment(at: position) else {
            return nil  // PassSegmentなし → Block
        }
        
        // 3. ペアのSegmentを取得
        guard let (targetEdge, targetSegment) = self.segment(withId: segment.pairedSegmentId) else {
            return nil  // ペアなし → Block
        }
        
        // 4. 目標位置を計算
        let targetPosition: Double
        if targetSegment.isEmpty {
            // 空セグメント → 常に同じ位置（ワープ）
            targetPosition = targetSegment.start
        } else {
            // 通常セグメント → 位置比率で補正
            let ratio = (position - segment.start) / (segment.end - segment.start)
            targetPosition = targetSegment.start + ratio * (targetSegment.end - targetSegment.start)
        }
        
        return (targetEdge, targetPosition)
    }
    
    /// バリデーション
    func validate() -> Bool {
        // 各エッジが有効
        guard edges.allSatisfy({ $0.validate() }) else {
            return false
        }
        
        // ペアの整合性チェック
        for edge in edges {
            for segment in edge.passSegments {
                // ペアが存在するか
                guard let (_, paired) = self.segment(withId: segment.pairedSegmentId) else {
                    return false
                }
                
                // 逆方向のペアリングが一致するか
                guard paired.pairedSegmentId == segment.id else {
                    return false
                }
            }
        }
        
        return true
    }
}

extension EdgeNavigationMap {
    /// デフォルトのエッジナビゲーションを生成（論理的に隣接する範囲のみPass）
    static func createDefault(displays: [Display]) -> EdgeNavigationMap {
        var edges: [DisplayEdge] = []
        
        // 各ディスプレイの各エッジについて
        for display in displays {
            guard let displayId = display.id as UUID? else { continue }
            
            for side in EdgeSide.allCases {
                var passSegments: [PassSegment] = []
                
                // 隣接するディスプレイを検索
                let adjacentDisplays = findAdjacentDisplays(
                    display: display,
                    side: side,
                    allDisplays: displays
                )
                
                for (adjacentDisplay, overlapRange, adjacentSide) in adjacentDisplays {
                    guard let adjacentId = adjacentDisplay.id as UUID? else { continue }
                    
                    // PassSegmentを作成（ペアは後で設定）
                    let segment = PassSegment(
                        start: overlapRange.lowerBound,
                        end: overlapRange.upperBound,
                        pairedSegmentId: UUID()  // 仮のID
                    )
                    passSegments.append(segment)
                }
                
                // エッジを作成
                let edge = DisplayEdge(
                    displayId: displayId,
                    side: side,
                    passSegments: passSegments
                )
                edges.append(edge)
            }
        }
        
        // TODO: ペアリングの設定（Phase 5で実装）
        
        return EdgeNavigationMap(edges: edges)
    }
    
    /// 隣接するディスプレイを検索
    private static func findAdjacentDisplays(
        display: Display,
        side: EdgeSide,
        allDisplays: [Display]
    ) -> [(Display, ClosedRange<Double>, EdgeSide)] {
        var result: [(Display, ClosedRange<Double>, EdgeSide)] = []
        let frame = display.logicalFrame
        let epsilon: CGFloat = 1.0
        
        for other in allDisplays {
            if other.id == display.id { continue }
            
            let otherFrame = other.logicalFrame
            
            // エッジごとに隣接チェック
            switch side {
            case .top:
                // top: frame.maxY == other.minY
                if abs(frame.maxY - otherFrame.minY) < epsilon {
                    let overlapStart = max(frame.minX, otherFrame.minX)
                    let overlapEnd = min(frame.maxX, otherFrame.maxX)
                    if overlapStart < overlapEnd {
                        let normalizedStart = (overlapStart - frame.minX) / frame.width
                        let normalizedEnd = (overlapEnd - frame.minX) / frame.width
                        result.append((other, normalizedStart...normalizedEnd, .bottom))
                    }
                }
            case .bottom:
                // bottom: frame.minY == other.maxY
                if abs(frame.minY - otherFrame.maxY) < epsilon {
                    let overlapStart = max(frame.minX, otherFrame.minX)
                    let overlapEnd = min(frame.maxX, otherFrame.maxX)
                    if overlapStart < overlapEnd {
                        let normalizedStart = (overlapStart - frame.minX) / frame.width
                        let normalizedEnd = (overlapEnd - frame.minX) / frame.width
                        result.append((other, normalizedStart...normalizedEnd, .top))
                    }
                }
            case .right:
                // right: frame.maxX == other.minX
                if abs(frame.maxX - otherFrame.minX) < epsilon {
                    let overlapStart = max(frame.minY, otherFrame.minY)
                    let overlapEnd = min(frame.maxY, otherFrame.maxY)
                    if overlapStart < overlapEnd {
                        // Y座標を上下反転して正規化（macOS座標系はY上向き、正規化は0=top）
                        let normalizedStart = (frame.maxY - overlapEnd) / frame.height
                        let normalizedEnd = (frame.maxY - overlapStart) / frame.height
                        result.append((other, normalizedStart...normalizedEnd, .left))
                    }
                }
            case .left:
                // left: frame.minX == other.maxX
                if abs(frame.minX - otherFrame.maxX) < epsilon {
                    let overlapStart = max(frame.minY, otherFrame.minY)
                    let overlapEnd = min(frame.maxY, otherFrame.maxY)
                    if overlapStart < overlapEnd {
                        // Y座標を上下反転して正規化
                        let normalizedStart = (frame.maxY - overlapEnd) / frame.height
                        let normalizedEnd = (frame.maxY - overlapStart) / frame.height
                        result.append((other, normalizedStart...normalizedEnd, .right))
                    }
                }
            }
        }
        
        return result
    }
}

