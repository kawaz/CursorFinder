// EdgeNavigation.swift
import Foundation

/// エッジの辺（上下左右）
enum EdgeSide: String, Codable, CaseIterable {
    case top
    case bottom
    case left
    case right
}

/// セグメント範囲
struct SegmentRange: Codable, Hashable {
    let start: Double
    let end: Double
    
    /// 空セグメント（ワープポイント）かどうか
    var isEmpty: Bool {
        start == end
    }
    
    /// 指定位置を含むか（閉区間 [start, end]）
    func contains(_ value: Double) -> Bool {
        guard !isEmpty else { return false }  // 空セグメントは検索対象外
        return start <= value && value <= end
    }
    
    /// バリデーション
    func validate() -> Bool {
        return start <= end  // start <= end（空セグメント許可）
    }
}

/// Pass可能なセグメント
struct PassSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let displayId: UUID  // このSegmentが属するDisplay（検索用）
    let side: EdgeSide
    
    // 論理座標での範囲（px単位、実座標値）
    let logical: SegmentRange
    
    // 物理座標での範囲（mm単位、実座標値）
    let physical: SegmentRange
    
    // ペアリング（アプリロジックで使用）
    let pairedSegmentId: UUID
    
    // デバッグ用ヒント（JSONの可読性向上、アプリロジックでは使用しない）
    let pairedDisplayId: UUID?
    let pairedDisplayName: String?
    let pairedSide: EdgeSide?
    
    init(
        id: UUID = UUID(),
        displayId: UUID,
        side: EdgeSide,
        logical: SegmentRange,
        physical: SegmentRange,
        pairedSegmentId: UUID,
        pairedDisplayId: UUID? = nil,
        pairedDisplayName: String? = nil,
        pairedSide: EdgeSide? = nil
    ) {
        self.id = id
        self.displayId = displayId
        self.side = side
        self.logical = logical
        self.physical = physical
        self.pairedSegmentId = pairedSegmentId
        self.pairedDisplayId = pairedDisplayId
        self.pairedDisplayName = pairedDisplayName
        self.pairedSide = pairedSide
    }
    
    /// バリデーション
    func validate() -> Bool {
        return logical.validate() && physical.validate()
    }
    
    /// 越境先の位置を計算
    /// - Parameter position: 現在の位置（実座標値）
    /// - Returns: ペア側の位置（実座標値）、またはnil
    func calculateTargetPosition(_ position: Double, pairedSegment: PassSegment) -> Double? {
        guard logical.contains(position) else {
            return nil
        }
        
        if pairedSegment.logical.isEmpty {
            // 空セグメント → ワープ
            return pairedSegment.logical.start
        } else {
            // 通常セグメント → 位置比率で補正
            let ratio = (position - logical.start) / (logical.end - logical.start)
            return pairedSegment.logical.start + ratio * (pairedSegment.logical.end - pairedSegment.logical.start)
        }
    }
}

/// エッジナビゲーションマップ（高速検索用）
struct EdgeNavigationMap {
    private var displays: [Display]
    private var segmentIndex: [UUID: (display: Display, segment: PassSegment)]
    
    init(displays: [Display]) {
        self.displays = displays
        
        // 全Segmentをインデックス化
        var index: [UUID: (Display, PassSegment)] = [:]
        for display in displays {
            for segment in display.passSegments {
                index[segment.id] = (display, segment)
            }
        }
        self.segmentIndex = index
    }
    
    /// セグメントIDで検索（O(1)）
    func segment(withId id: UUID) -> (display: Display, segment: PassSegment)? {
        segmentIndex[id]
    }
    
    /// 越境処理
    func handleCrossing(
        at position: Double,
        displayId: UUID,
        side: EdgeSide
    ) -> (targetDisplay: Display, targetPosition: Double)? {
        // ディスプレイを取得
        guard let display = displays.first(where: { $0.id == displayId }) else {
            return nil
        }
        
        // そのディスプレイの指定エッジのPassSegmentを検索
        guard let segment = display.passSegments.first(where: { 
            $0.side == side && $0.logical.contains(position)
        }) else {
            return nil  // Block
        }
        
        // ペアのSegmentを取得
        guard let (targetDisplay, pairedSegment) = segment(withId: segment.pairedSegmentId) else {
            return nil
        }
        
        // 目標位置を計算
        guard let targetPosition = segment.calculateTargetPosition(position, pairedSegment: pairedSegment) else {
            return nil
        }
        
        return (targetDisplay, targetPosition)
    }
}
