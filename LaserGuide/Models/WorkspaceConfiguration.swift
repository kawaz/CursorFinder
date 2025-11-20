// WorkspaceConfiguration.swift
import Foundation

/// ワークスペース設定
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String  // DisplayFingerprintの組み合わせから生成
    
    // 保存する物理情報
    var physicalLayouts: [PhysicalLayout]
    var navigation: EdgeNavigationMap
    
    let metadata: Metadata
    
    struct Metadata: Codable {
        let created: Date
        var modified: Date
    }
    
    init(
        id: UUID = UUID(),
        configurationKey: String,
        physicalLayouts: [PhysicalLayout],
        navigation: EdgeNavigationMap,
        metadata: Metadata? = nil
    ) {
        self.id = id
        self.configurationKey = configurationKey
        self.physicalLayouts = physicalLayouts
        self.navigation = navigation
        
        if let metadata = metadata {
            self.metadata = metadata
        } else {
            self.metadata = Metadata(created: Date(), modified: Date())
        }
    }
    
    /// 物理座標を正規化（全体の最小点を原点に）
    mutating func normalize() {
        physicalLayouts = physicalLayouts.normalized()
    }
    
    /// バリデーション
    func validate() -> Bool {
        // 物理レイアウトとナビゲーションマップが一致するか
        let layoutDisplayIds = Set(physicalLayouts.map { $0.id })
        let navigationDisplayIds = Set(navigation.edges.map { $0.displayId })
        
        // すべてのナビゲーションエッジが物理レイアウトに対応しているか
        guard navigationDisplayIds.isSubset(of: layoutDisplayIds) else {
            return false
        }
        
        // ナビゲーションマップのバリデーション
        return navigation.validate()
    }
}

/// 実行時のワークスペース（論理+物理の統合）
struct Workspace {
    let configuration: WorkspaceConfiguration
    let displays: [Display]
    
    init(configuration: WorkspaceConfiguration, screens: [NSScreen]) {
        self.configuration = configuration
        self.displays = Self.mergeLogicalAndPhysical(configuration, screens: screens)
    }
    
    /// 論理情報と物理情報をマージ
    private static func mergeLogicalAndPhysical(
        _ config: WorkspaceConfiguration,
        screens: [NSScreen]
    ) -> [Display] {
        var result: [Display] = []
        
        for layout in config.physicalLayouts {
            // 対応するNSScreenを検索
            guard let screen = screens.first(where: {
                let fingerprint = DisplayFingerprint(screen: $0)
                return fingerprint == layout.fingerprint
            }) else {
                // 対応するスクリーンが見つからない（ディスプレイが外されている）
                continue
            }
            
            // マージ
            let display = Display.merge(screen: screen, layout: layout)
            result.append(display)
        }
        
        return result
    }
    
    /// デフォルトのワークスペースを作成
    static func createDefault(screens: [NSScreen]) -> Workspace {
        var displays: [Display] = []
        var physicalLayouts: [PhysicalLayout] = []
        
        // 各スクリーンからディスプレイを作成
        for screen in screens {
            let display = Display.createDefault(screen: screen)
            displays.append(display)
            
            // PhysicalLayoutに変換
            let layout = PhysicalLayout(
                id: display.id,
                fingerprint: display.fingerprint,
                position: display.physicalPosition,
                size: display.physicalSize
            )
            physicalLayouts.append(layout)
        }
        
        // 物理座標を正規化
        physicalLayouts = physicalLayouts.normalized()
        
        // デフォルトのナビゲーションを生成
        let navigation = EdgeNavigationMap.createDefault(displays: displays)
        
        // 設定キーを生成
        let fingerprints = displays.map { $0.fingerprint }
        let configKey = generateConfigurationKey(fingerprints: fingerprints)
        
        // 設定を作成
        let config = WorkspaceConfiguration(
            configurationKey: configKey,
            physicalLayouts: physicalLayouts,
            navigation: navigation
        )
        
        return Workspace(configuration: config, screens: screens)
    }
}

