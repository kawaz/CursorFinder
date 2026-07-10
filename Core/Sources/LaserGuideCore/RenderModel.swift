// RenderModel (DR-0008: WKWebView 純 view のための表示専用 JSON)
//
// AppState から**表示に必要な値だけ**を導出する Codable 型。JS 側はこの JSON を描画するだけで、
// 幾何ロジック (エッジ検出 / 座標変換 / 隣接判定) を持たない (DR-0008 決定 1)。
//
// 導出は純関数 `RenderModel.derive(from:)`。テストは AppState 列 → RenderModel 列で回す。
// キャリブレーション編集中は candidatePose (= dragMove の中間値) を適用した表示物理値も
// 併せて返す (DR-0008 決定 3 のプレビュー表示の Swift 側正本)。
//
// 型は Swift が正本 (DR-0007 決定 6)。JSON キーは JS 慣習の camelCase をそのまま採用。
import Foundation

public struct RenderModel: Codable, Equatable, Sendable {

    // MARK: - Nested types

    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Rect: Codable, Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double
        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
    }

    /// 1 モニタの描画に必要な情報。
    /// - `logicalBounds`: OS 由来の論理矩形 (px、pose の影響を受けない)
    /// - `physicalBounds`: 有効な pose (= プレビュー中なら candidatePose、そうでなければ確定 pose) を
    ///   4 隅に適用した mm 空間の bounding rect。プレビュー中は candidate 適用済みなので JS 側は
    ///   そのまま描けば「確定前の候補位置」が見える (DR-0008 決定 3 の楽観表示の Swift 正本)
    /// - `poseTranslateMm`: 確定 pose の translate (mm)。JS が dragMove 中の candidatePose を
    ///   構築するために必要 (candidate = confirmed origin + drag delta)
    /// - `candidatePoseTranslateMm`: プレビュー適用中のみ埋まる。JS が「今送信中の中間値」を
    ///   知る必要がある場合に使う (通常は physicalBounds を見れば足りる)
    public struct Display: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var logicalBounds: Rect
        public var physicalBounds: Rect
        public var poseTranslateMm: Point
        public var scaleXMmPerPx: Double
        public var scaleYMmPerPx: Double
        public var hasMillimeterInfo: Bool
        public var candidatePoseTranslateMm: Point?
        public var isDragging: Bool

        public init(id: String, name: String, logicalBounds: Rect, physicalBounds: Rect,
                    poseTranslateMm: Point, scaleXMmPerPx: Double, scaleYMmPerPx: Double,
                    hasMillimeterInfo: Bool, candidatePoseTranslateMm: Point?, isDragging: Bool) {
            self.id = id; self.name = name; self.logicalBounds = logicalBounds
            self.physicalBounds = physicalBounds; self.poseTranslateMm = poseTranslateMm
            self.scaleXMmPerPx = scaleXMmPerPx; self.scaleYMmPerPx = scaleYMmPerPx
            self.hasMillimeterInfo = hasMillimeterInfo
            self.candidatePoseTranslateMm = candidatePoseTranslateMm; self.isDragging = isDragging
        }
    }

    /// 1 セグメント (OS 自動 or ユーザ編集) の描画情報。edgeType は WarpTables で導出済みの派生語彙
    /// (DR-0006 決定 1)。JS 側は「segment を辺として描く + edgeType で色分け」だけ担当。
    public struct Segment: Codable, Equatable, Sendable {
        public var id: String
        public var displayId: String
        public var side: String           // "top" / "bottom" / "left" / "right"
        public var logicalStart: Double
        public var logicalEnd: Double
        public var edgeType: String       // "pp" / "pb" / "bp" / "bb"
        public var source: String         // "os" / "user"
        public var pairedSegmentId: String

        public init(id: String, displayId: String, side: String,
                    logicalStart: Double, logicalEnd: Double,
                    edgeType: String, source: String, pairedSegmentId: String) {
            self.id = id; self.displayId = displayId; self.side = side
            self.logicalStart = logicalStart; self.logicalEnd = logicalEnd
            self.edgeType = edgeType; self.source = source
            self.pairedSegmentId = pairedSegmentId
        }
    }

    // MARK: - Fields

    public var displays: [Display]
    public var segments: [Segment]
    /// 現在ドラッグ中のモニタ id (JS 側の優先度リスト・ハイライト用)。
    public var draggingDisplayId: String?
    /// プレビュー tables が構築済みかどうか (JS 側のインジケータ用途)。
    public var hasPreview: Bool
    /// 表示座標系のヒント。y-down (DR-0005) を明示、JS 側が誤って反転しないため。
    public var yAxisDirection: String

    public init(displays: [Display], segments: [Segment],
                draggingDisplayId: String?, hasPreview: Bool, yAxisDirection: String = "down") {
        self.displays = displays; self.segments = segments
        self.draggingDisplayId = draggingDisplayId; self.hasPreview = hasPreview
        self.yAxisDirection = yAxisDirection
    }
}

// MARK: - Derivation

extension RenderModel {

    /// AppState から RenderModel を導出する純関数。キャリブレーション編集中は candidatePose を
    /// 適用した派生 displays を使って physicalBounds を計算する (プレビュー描画の Swift 正本)。
    /// EdgeType は「有効な displays + userSegments」から都度構築した WarpTables で導出するため、
    /// candidatePose が隣接関係を変える (OS 隣接の有無が変わる) 場合もプレビューに反映される。
    public static func derive(from state: AppState) -> RenderModel {
        let effectiveDisplays = state.calibration.previewDisplays(basedOn: state.displays)
        let tables = state.calibration.candidatePoses.isEmpty
            ? state.tables
            : WarpTables(displays: effectiveDisplays, userSegments: state.userSegments)

        let displayModels: [Display] = effectiveDisplays.map { d -> Display in
            let originalPose = state.displays.first(where: { $0.id == d.id })?.pose ?? d.pose
            let candidate = state.calibration.candidatePoses[d.id]
            let candidatePoint: Point?
            if let c = candidate { candidatePoint = Point(x: c.translate.x, y: c.translate.y) }
            else { candidatePoint = nil }
            return Display(
                id: d.id,
                name: displayName(for: d.id),
                logicalBounds: Rect(minX: d.logicalBounds.minX, minY: d.logicalBounds.minY,
                                    maxX: d.logicalBounds.maxX, maxY: d.logicalBounds.maxY),
                physicalBounds: physicalBoundingRect(of: d),
                poseTranslateMm: Point(x: originalPose.translate.x, y: originalPose.translate.y),
                scaleXMmPerPx: originalPose.scaleX,
                scaleYMmPerPx: originalPose.scaleY,
                hasMillimeterInfo: true,
                candidatePoseTranslateMm: candidatePoint,
                isDragging: state.calibration.draggingDisplayId == d.id
            )
        }

        var segments: [Segment] = []
        for os in tables.osSegments {
            segments.append(Segment(
                id: os.id, displayId: os.displayId, side: os.side.rawValue,
                logicalStart: os.logicalStart, logicalEnd: os.logicalEnd,
                edgeType: edgeTypeString(tables.edgeType(displayId: os.displayId, side: os.side, along: midAlong(os))),
                source: "os", pairedSegmentId: os.pairedSegmentId
            ))
        }
        for user in tables.userSegments {
            segments.append(Segment(
                id: user.id, displayId: user.displayId, side: user.side.rawValue,
                logicalStart: user.logicalStart, logicalEnd: user.logicalEnd,
                edgeType: edgeTypeString(tables.edgeType(displayId: user.displayId, side: user.side, along: midAlong(user))),
                source: "user", pairedSegmentId: user.pairedSegmentId
            ))
        }

        return RenderModel(
            displays: displayModels,
            segments: segments,
            draggingDisplayId: state.calibration.draggingDisplayId,
            hasPreview: state.calibration.previewTables != nil
        )
    }

    /// 論理矩形 4 隅に pose を適用した bounding rect (mm)。scale は正値制約 (DisplayPose init) が
    /// あるので min = translate + minLogical * scale、max = translate + maxLogical * scale で足りる。
    /// (引数の `d` は `LaserGuideCore.Display`。`RenderModel.Display` (Nested) と混同しないよう完全修飾)
    private static func physicalBoundingRect(of d: LaserGuideCore.Display) -> Rect {
        let x0 = d.pose.translate.x + d.logicalBounds.minX * d.pose.scaleX
        let x1 = d.pose.translate.x + d.logicalBounds.maxX * d.pose.scaleX
        let y0 = d.pose.translate.y + d.logicalBounds.minY * d.pose.scaleY
        let y1 = d.pose.translate.y + d.logicalBounds.maxY * d.pose.scaleY
        return Rect(minX: min(x0, x1), minY: min(y0, y1), maxX: max(x0, x1), maxY: max(y0, y1))
    }

    private static func midAlong(_ s: PassSegment) -> Double {
        (s.logicalStart + s.logicalEnd) / 2
    }

    private static func edgeTypeString(_ t: EdgeType) -> String {
        switch t { case .pp: return "pp"; case .pb: return "pb"; case .bp: return "bp"; case .bb: return "bb" }
    }

    /// Phase 1: 表示名は display id をそのまま返す (Phase 2 で DisplaySnapshotProvider から
    /// os_name / display_name を運ぶ経路に置き換える。DR-0008 決定 5 のプロトタイプ流用対象)。
    private static func displayName(for id: String) -> String { id }
}
