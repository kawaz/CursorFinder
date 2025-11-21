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
        
        // OS標準のPassSegmentを生成
        generateOSPassSegments(displays: &displays)
        
        // ユーザーPassSegmentはOS標準をコピー（初期状態）
        for i in 0..<displays.count {
            displays[i].passSegments = displays[i].osPassSegments
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
    
    /// OS標準のPassSegmentを生成（論理的に隣接している範囲）
    private static func generateOSPassSegments(displays: inout [Display]) {
        // TODO: 論理的隣接を検出してPassSegmentを生成
        // Phase 2で実装
    }
}
