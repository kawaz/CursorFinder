// WorkspaceConfiguration.swift
import Foundation
import Cocoa

/// ワークスペース設定
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String
    var displays: [Display]
    var metadata: ConfigMetadata

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

    /// 読み込み後の初期化（Display参照とペアリングを設定）
    mutating func initialize() {
        // Display参照を設定
        for i in 0..<displays.count {
            let display = displays[i]

            for j in 0..<displays[i].passSegments.count {
                displays[i].passSegments[j].display = display
            }

            for j in 0..<displays[i].osPassSegments.count {
                displays[i].osPassSegments[j].display = display
            }
        }

        // ペアリングを設定
        linkPairedSegments()
    }

    /// 全PassSegmentのペアリングを設定
    private mutating func linkPairedSegments() {
        // 全Segmentをインデックス化
        var segmentMap: [UUID: (displayIndex: Int, segmentIndex: Int, isOS: Bool)] = [:]

        for (i, display) in displays.enumerated() {
            for (j, segment) in display.passSegments.enumerated() {
                segmentMap[segment.id] = (i, j, false)
            }
            for (j, segment) in display.osPassSegments.enumerated() {
                segmentMap[segment.id] = (i, j, true)
            }
        }

        // ペアを設定（userPassSegments）
        for i in 0..<displays.count {
            for j in 0..<displays[i].passSegments.count {
                let pairedId = displays[i].passSegments[j].pairedSegmentId
                if let (di, si, isOS) = segmentMap[pairedId] {
                    if isOS {
                        displays[i].passSegments[j].pairedSegment = displays[di].osPassSegments[si]
                    } else {
                        displays[i].passSegments[j].pairedSegment = displays[di].passSegments[si]
                    }
                }
            }
        }

        // ペアを設定（osPassSegments）
        for i in 0..<displays.count {
            for j in 0..<displays[i].osPassSegments.count {
                let pairedId = displays[i].osPassSegments[j].pairedSegmentId
                if let (di, si, isOS) = segmentMap[pairedId] {
                    if isOS {
                        displays[i].osPassSegments[j].pairedSegment = displays[di].osPassSegments[si]
                    } else {
                        displays[i].osPassSegments[j].pairedSegment = displays[di].passSegments[si]
                    }
                }
            }
        }
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

        // OS標準のPassSegmentを生成（論理的隣接を検出）
        generateOSPassSegments(displays: &displays)

        // Display参照を設定
        for i in 0..<displays.count {
            let display = displays[i]
            for j in 0..<displays[i].osPassSegments.count {
                displays[i].osPassSegments[j].display = display
            }
        }

        // ペアリングを設定
        linkOSPassSegments(displays: &displays)

        // ユーザーPassSegmentはOS標準をコピー（初期状態）
        for i in 0..<displays.count {
            let display = displays[i]
            // osPassSegmentsをディープコピー
            displays[i].passSegments = displays[i].osPassSegments.map { seg in
                var newSeg = PassSegment(
                    id: UUID(),
                    displayId: seg.displayId,
                    side: seg.side,
                    logical: seg.logical,
                    physical: seg.physical,
                    pairedSegmentId: seg.pairedSegmentId
                )
                newSeg.display = display
                return newSeg
            }
        }

        // userPassSegmentsのペアリングも設定
        linkUserPassSegments(displays: &displays)

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

    /// OS標準のPassSegmentを生成（論理的に隣接している範囲）
    private static func generateOSPassSegments(displays: inout [Display]) {
        let epsilon: CGFloat = 1.0

        for i in 0..<displays.count {
            let display = displays[i]
            let frame = display.coordinates.logical
            var segments: [PassSegment] = []

            // 各エッジについて隣接ディスプレイを検索
            for side in EdgeSide.allCases {
                let adjacentSegments = findAdjacentSegments(
                    display: display,
                    side: side,
                    allDisplays: displays,
                    epsilon: epsilon
                )

                segments.append(contentsOf: adjacentSegments)
            }

            displays[i].osPassSegments = segments
        }
    }

    /// 隣接するディスプレイを検出してPassSegmentを生成
    private static func findAdjacentSegments(
        display: Display,
        side: EdgeSide,
        allDisplays: [Display],
        epsilon: CGFloat
    ) -> [PassSegment] {
        var segments: [PassSegment] = []
        let frame = display.coordinates.logical

        for other in allDisplays {
            if other.id == display.id { continue }

            let otherFrame = other.coordinates.logical
            var isAdjacent = false
            var overlapStart: CGFloat = 0
            var overlapEnd: CGFloat = 0

            // エッジごとに隣接チェック
            switch side {
            case .top:
                // top: frame.maxY == other.minY
                if abs(frame.position.y + frame.size.height - otherFrame.position.y) < epsilon {
                    isAdjacent = true
                    overlapStart = max(frame.position.x, otherFrame.position.x)
                    overlapEnd = min(frame.position.x + frame.size.width, otherFrame.position.x + otherFrame.size.width)
                }
            case .bottom:
                // bottom: frame.minY == other.maxY
                if abs(frame.position.y - (otherFrame.position.y + otherFrame.size.height)) < epsilon {
                    isAdjacent = true
                    overlapStart = max(frame.position.x, otherFrame.position.x)
                    overlapEnd = min(frame.position.x + frame.size.width, otherFrame.position.x + otherFrame.size.width)
                }
            case .right:
                // right: frame.maxX == other.minX
                if abs(frame.position.x + frame.size.width - otherFrame.position.x) < epsilon {
                    isAdjacent = true
                    overlapStart = max(frame.position.y, otherFrame.position.y)
                    overlapEnd = min(frame.position.y + frame.size.height, otherFrame.position.y + otherFrame.size.height)
                }
            case .left:
                // left: frame.minX == other.maxX
                if abs(frame.position.x - (otherFrame.position.x + otherFrame.size.width)) < epsilon {
                    isAdjacent = true
                    overlapStart = max(frame.position.y, otherFrame.position.y)
                    overlapEnd = min(frame.position.y + frame.size.height, otherFrame.position.y + otherFrame.size.height)
                }
            }

            if isAdjacent && overlapStart < overlapEnd {
                // PassSegmentを生成
                let logicalStart: Double
                let logicalEnd: Double
                let physicalStart: Double
                let physicalEnd: Double

                switch side {
                case .top, .bottom:
                    // X軸での範囲
                    logicalStart = overlapStart - frame.position.x
                    logicalEnd = overlapEnd - frame.position.x

                    let physicalFrame = display.coordinates.physical
                    physicalStart = (logicalStart / frame.size.width) * physicalFrame.size.width
                    physicalEnd = (logicalEnd / frame.size.width) * physicalFrame.size.width

                case .left, .right:
                    // Y軸での範囲
                    logicalStart = overlapStart - frame.position.y
                    logicalEnd = overlapEnd - frame.position.y

                    let physicalFrame = display.coordinates.physical
                    physicalStart = (logicalStart / frame.size.height) * physicalFrame.size.height
                    physicalEnd = (logicalEnd / frame.size.height) * physicalFrame.size.height
                }

                let segment = PassSegment(
                    displayId: display.id,
                    side: side,
                    logical: SegmentRange(start: logicalStart, end: logicalEnd),
                    physical: SegmentRange(start: physicalStart, end: physicalEnd)
                )

                segments.append(segment)
            }
        }

        return segments
    }

    /// osPassSegmentsのペアリングを設定
    private static func linkOSPassSegments(displays: inout [Display]) {
        // 全osPassSegmentをインデックス化
        var segmentMap: [UUID: (displayIndex: Int, segmentIndex: Int)] = [:]

        for (i, display) in displays.enumerated() {
            for (j, segment) in display.osPassSegments.enumerated() {
                segmentMap[segment.id] = (i, j)
            }
        }

        // ペアを設定（相互に参照）
        for i in 0..<displays.count {
            for j in 0..<displays[i].osPassSegments.count {
                // 対向するセグメントを探す（未実装、Phase 2で完成させる）
                // 現時点ではpairedSegmentIdのみ設定
            }
        }
    }

    /// userPassSegmentsのペアリングを設定
    private static func linkUserPassSegments(displays: inout [Display]) {
        // 同様の処理
    }
}
