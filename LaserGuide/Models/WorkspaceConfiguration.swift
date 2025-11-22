// WorkspaceConfiguration.swift
import Foundation
import Cocoa

/// ワークスペース設定
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String
    var displays: [Display]
    var metadata: ConfigMetadata

    // Runtime用Map（JSON除外）
    private var _displayMap: [UUID: Display]?
    private var _segmentMap: [UUID: PassSegment]?

    enum CodingKeys: String, CodingKey {
        case id, configurationKey, displays, metadata
    }

    // MARK: - Runtime Accessors

    /// DisplayをIDで取得
    subscript(displayId: UUID) -> Display? {
        mutating get {
            if _displayMap == nil { buildMaps() }
            return _displayMap?[displayId]
        }
    }

    /// PassSegmentをIDで取得
    subscript(segmentId: UUID) -> PassSegment? {
        mutating get {
            if _segmentMap == nil { buildMaps() }
            return _segmentMap?[segmentId]
        }
    }

    /// PassSegmentのペアを取得
    mutating func pairedSegment(of segment: PassSegment) -> PassSegment? {
        self[segment.pairedSegmentId]
    }

    /// PassSegmentが属するDisplayを取得
    mutating func display(of segment: PassSegment) -> Display? {
        self[segment.displayId]
    }

    /// Runtime Mapを構築
    private mutating func buildMaps() {
        var displayMap: [UUID: Display] = [:]
        var segmentMap: [UUID: PassSegment] = [:]

        for display in displays {
            displayMap[display.id] = display
            for segment in display.passSegments {
                segmentMap[segment.id] = segment
            }
            for segment in display.osPassSegments {
                segmentMap[segment.id] = segment
            }
        }

        _displayMap = displayMap
        _segmentMap = segmentMap
    }

    /// Mapをクリア（displays変更後に呼ぶ）
    mutating func invalidateMaps() {
        _displayMap = nil
        _segmentMap = nil
    }

    struct ConfigMetadata: Codable {
        let created: Date
        var modified: Date

        // アプリバージョン（Info.plistから）
        let appVersion: String
        let appBuildNumber: String

        // Git情報（ビルド時にInfo.plistに埋め込む、オプショナル）
        let gitCommit: String?
        let gitCommitFull: String?
        let gitBranch: String?
        let gitTag: String?
        let gitDescribe: String?
        let buildDate: String?
    }

    init(
        id: UUID = UUID(),
        configurationKey: String,
        displays: [Display],
        metadata: ConfigMetadata? = nil
    ) {
        self.id = id
        self.configurationKey = configurationKey
        self.displays = displays

        if let metadata = metadata {
            self.metadata = metadata
        } else {
            // デフォルトのメタデータを生成
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let appBuildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

            self.metadata = ConfigMetadata(
                created: Date(),
                modified: Date(),
                appVersion: appVersion,
                appBuildNumber: appBuildNumber,
                gitCommit: Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String,
                gitCommitFull: Bundle.main.object(forInfoDictionaryKey: "GitCommitFull") as? String,
                gitBranch: Bundle.main.object(forInfoDictionaryKey: "GitBranch") as? String,
                gitTag: Bundle.main.object(forInfoDictionaryKey: "GitTag") as? String,
                gitDescribe: Bundle.main.object(forInfoDictionaryKey: "GitDescribe") as? String,
                buildDate: Bundle.main.object(forInfoDictionaryKey: "BuildDate") as? String
            )
        }
    }

    /// 物理座標を正規化（全体の最小点を原点に）
    mutating func normalize() {
        guard !displays.isEmpty else { return }

        let minX = displays.map { $0.coordinates.physical.position.x }.min() ?? 0
        let minY = displays.map { $0.coordinates.physical.position.y }.min() ?? 0

        for i in 0..<displays.count {
            displays[i].coordinates.physical.position.x -= minX
            displays[i].coordinates.physical.position.y -= minY

            // visibleFrameも調整
            displays[i].coordinates.physical.visibleFrame.origin.x -= minX
            displays[i].coordinates.physical.visibleFrame.origin.y -= minY
        }
    }

    /// バリデーション
    func validate() -> Bool {
        // 全Displayが有効
        guard !displays.isEmpty else { return false }

        // 全PassSegmentが有効
        for display in displays {
            for segment in display.passSegments {
                if !segment.validate() {
                    return false
                }
            }
        }

        return true
    }

}

/// 実行時のワークスペース（Workspace型は不要、WorkspaceConfigurationがそのまま使える）
extension WorkspaceConfiguration {
    /// デフォルトのワークスペースを作成
    static func createDefault(screens: [NSScreen]) -> WorkspaceConfiguration {
        // 各スクリーンからDisplayを作成
        var displays = screens.map { Display.create(from: $0) }

        // 物理座標を正規化
        let minX = displays.map { $0.coordinates.physical.position.x }.min() ?? 0
        let minY = displays.map { $0.coordinates.physical.position.y }.min() ?? 0

        for i in 0..<displays.count {
            displays[i].coordinates.physical.position.x -= minX
            displays[i].coordinates.physical.position.y -= minY
        }

        // OS標準のPassSegmentを生成（論理的隣接を検出 + ペアリング）
        generateAndLinkOSPassSegments(displays: &displays)

        // ユーザーPassSegmentはOS標準をコピー（初期状態）
        // osPassSegments間のペアIDマッピングを作成
        var osToUserIdMap: [UUID: UUID] = [:]
        for display in displays {
            for seg in display.osPassSegments {
                osToUserIdMap[seg.id] = UUID()
            }
        }

        for i in 0..<displays.count {
            displays[i].passSegments = displays[i].osPassSegments.map { seg in
                PassSegment(
                    id: osToUserIdMap[seg.id]!,
                    displayId: seg.displayId,
                    side: seg.side,
                    logical: seg.logical,
                    physical: seg.physical,
                    pairedSegmentId: osToUserIdMap[seg.pairedSegmentId]!
                )
            }
        }

        // 設定キーを生成
        let fingerprints = displays.map {
            DisplayFingerprint(
                hardwareId: HardwareIdentifier(
                    vendorID: $0.hardware.vendorID,
                    modelID: $0.hardware.modelID,
                    serialNumber: $0.hardware.serialNumber
                ),
                resolution: $0.display.resolution.points,
                backingScaleFactor: $0.display.resolution.backingScaleFactor
            )
        }
        let configKey = generateConfigurationKey(fingerprints: fingerprints)

        return WorkspaceConfiguration(
            configurationKey: configKey,
            displays: displays
        )
    }

    /// OS標準のPassSegmentを生成してペアリング
    private static func generateAndLinkOSPassSegments(displays: inout [Display]) {
        let epsilon: CGFloat = 1.0

        // 隣接情報を収集: (displayIndex, side, otherDisplayIndex, otherSide, overlap範囲)
        struct AdjacencyInfo {
            let displayIndex: Int
            let side: EdgeSide
            let otherDisplayIndex: Int
            let otherSide: EdgeSide
            let logicalRange: SegmentRange
            let physicalRange: SegmentRange
            var segmentId: UUID = UUID()
            var pairedSegmentId: UUID?
        }

        var adjacencies: [AdjacencyInfo] = []

        // 全ディスプレイペアの隣接を検出
        for i in 0..<displays.count {
            let display = displays[i]
            let frame = display.coordinates.logical

            for side in EdgeSide.allCases {
                let oppositeSide: EdgeSide
                switch side {
                case .top: oppositeSide = .bottom
                case .bottom: oppositeSide = .top
                case .left: oppositeSide = .right
                case .right: oppositeSide = .left
                }

                for j in 0..<displays.count where j != i {
                    let other = displays[j]
                    let otherFrame = other.coordinates.logical

                    var isAdjacent = false
                    var overlapStart: CGFloat = 0
                    var overlapEnd: CGFloat = 0

                    switch side {
                    case .top:
                        if abs(frame.position.y + frame.size.height - otherFrame.position.y) < epsilon {
                            isAdjacent = true
                            overlapStart = max(frame.position.x, otherFrame.position.x)
                            overlapEnd = min(frame.position.x + frame.size.width, otherFrame.position.x + otherFrame.size.width)
                        }
                    case .bottom:
                        if abs(frame.position.y - (otherFrame.position.y + otherFrame.size.height)) < epsilon {
                            isAdjacent = true
                            overlapStart = max(frame.position.x, otherFrame.position.x)
                            overlapEnd = min(frame.position.x + frame.size.width, otherFrame.position.x + otherFrame.size.width)
                        }
                    case .right:
                        if abs(frame.position.x + frame.size.width - otherFrame.position.x) < epsilon {
                            isAdjacent = true
                            overlapStart = max(frame.position.y, otherFrame.position.y)
                            overlapEnd = min(frame.position.y + frame.size.height, otherFrame.position.y + otherFrame.size.height)
                        }
                    case .left:
                        if abs(frame.position.x - (otherFrame.position.x + otherFrame.size.width)) < epsilon {
                            isAdjacent = true
                            overlapStart = max(frame.position.y, otherFrame.position.y)
                            overlapEnd = min(frame.position.y + frame.size.height, otherFrame.position.y + otherFrame.size.height)
                        }
                    }

                    if isAdjacent && overlapStart < overlapEnd {
                        let logicalStart: Double
                        let logicalEnd: Double
                        let physicalStart: Double
                        let physicalEnd: Double

                        switch side {
                        case .top, .bottom:
                            logicalStart = overlapStart - frame.position.x
                            logicalEnd = overlapEnd - frame.position.x
                            let pf = display.coordinates.physical
                            physicalStart = (logicalStart / frame.size.width) * pf.size.width
                            physicalEnd = (logicalEnd / frame.size.width) * pf.size.width
                        case .left, .right:
                            logicalStart = overlapStart - frame.position.y
                            logicalEnd = overlapEnd - frame.position.y
                            let pf = display.coordinates.physical
                            physicalStart = (logicalStart / frame.size.height) * pf.size.height
                            physicalEnd = (logicalEnd / frame.size.height) * pf.size.height
                        }

                        adjacencies.append(AdjacencyInfo(
                            displayIndex: i,
                            side: side,
                            otherDisplayIndex: j,
                            otherSide: oppositeSide,
                            logicalRange: SegmentRange(start: logicalStart, end: logicalEnd),
                            physicalRange: SegmentRange(start: physicalStart, end: physicalEnd)
                        ))
                    }
                }
            }
        }

        // ペアリング: 対向するセグメントを見つけてIDをリンク
        for i in 0..<adjacencies.count {
            for j in (i + 1)..<adjacencies.count {
                let a = adjacencies[i]
                let b = adjacencies[j]
                // A→BとB→Aのペアを見つける
                if a.displayIndex == b.otherDisplayIndex &&
                   a.otherDisplayIndex == b.displayIndex &&
                   a.side == b.otherSide &&
                   a.otherSide == b.side {
                    adjacencies[i].pairedSegmentId = adjacencies[j].segmentId
                    adjacencies[j].pairedSegmentId = adjacencies[i].segmentId
                }
            }
        }

        // PassSegmentを生成してDisplayに設定
        for i in 0..<displays.count {
            displays[i].osPassSegments = adjacencies
                .filter { $0.displayIndex == i && $0.pairedSegmentId != nil }
                .map { adj in
                    PassSegment(
                        id: adj.segmentId,
                        displayId: displays[i].id,
                        side: adj.side,
                        logical: adj.logicalRange,
                        physical: adj.physicalRange,
                        pairedSegmentId: adj.pairedSegmentId!
                    )
                }
        }
    }
}
