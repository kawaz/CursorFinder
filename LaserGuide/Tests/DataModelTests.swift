// DataModelTests.swift
import Foundation
import Cocoa

/// データモデル完全動作確認
class DataModelTests {
    static func runAll() {
        print("=== LaserGuide v2 データモデル完全動作確認 ===\n")
        
        // Phase 1: サンプル設定作成
        testCreateConfiguration()
        
        // Phase 2: 保存・ロード確認
        testSaveAndLoad()
        
        // Phase 3: キャッシュ確認
        testCacheAndReferences()
        
        print("\n✅ 全テスト完了")
    }
    
    static func testCreateConfiguration() {
        print("=== Phase 1: サンプル設定作成 ===\n")
        
        let screens = NSScreen.screens
        guard screens.count >= 2 else {
            print("⚠️ 2台以上のディスプレイが必要です")
            return
        }
        
        // Workspace作成
        var workspace = WorkspaceConfiguration.createDefault(screens: screens)
        
        print("✅ Workspace作成: \(workspace.configurationKey)")
        print("   Display数: \(workspace.displays.count)")
        
        // PassSegment手動設定（LG右下→内蔵右上ワープ）
        if workspace.displays.count >= 2 {
            let builtin = workspace.displays[0]
            let lg = workspace.displays[1]
            
            var seg1 = PassSegment(
                displayId: builtin.id,
                side: .top,
                logical: SegmentRange(start: 0.0, end: 3440.0),
                physical: SegmentRange(start: 0.0, end: 342.6)
            )
            
            var seg2 = PassSegment(
                displayId: builtin.id,
                side: .top,
                logical: SegmentRange(start: 3456.0, end: 3456.0),
                physical: SegmentRange(start: 344.2, end: 344.2)
            )
            
            var seg3 = PassSegment(
                displayId: lg.id,
                side: .bottom,
                logical: SegmentRange(start: 0.0, end: 1125.0),
                physical: SegmentRange(start: 0.0, end: 344.2)
            )
            
            var seg4 = PassSegment(
                displayId: lg.id,
                side: .bottom,
                logical: SegmentRange(start: 1125.0, end: 3440.0),
                physical: SegmentRange(start: 344.2, end: 1052.7)
            )
            
            // Display参照設定
            seg1.display = builtin
            seg2.display = builtin
            seg3.display = lg
            seg4.display = lg
            
            // ペアリング
            seg1.pairedSegment = seg3
            seg3.pairedSegment = seg1
            seg2.pairedSegment = seg4
            seg4.pairedSegment = seg2
            
            workspace.displays[0].passSegments = [seg1, seg2]
            workspace.displays[1].passSegments = [seg3, seg4]
            
            print("✅ PassSegment設定完了")
            print("   内蔵 top: \(workspace.displays[0].passSegments.count)個")
            print("   LG bottom: \(workspace.displays[1].passSegments.count)個")
        }
        
        // JSONダンプ
        dumpJSON(workspace, title: "Phase 1: 作成直後のWorkspace")
        
        // AppConfiguration作成
        var appConfig = AppConfiguration(
            workspaceKey: workspace.configurationKey,
            laser: AppConfiguration.LaserConfiguration(),
            edgeNavigation: AppConfiguration.EdgeNavigationConfiguration()
        )
        appConfig.workspace = workspace
        
        dumpJSON(appConfig, title: "Phase 1: 作成直後のAppConfiguration")
    }
    
    static func testSaveAndLoad() {
        print("\n=== Phase 2: 保存・ロード確認 ===\n")
        
        // 保存
        let screens = NSScreen.screens
        let workspace = WorkspaceConfiguration.createDefault(screens: screens)
        
        ConfigurationManager.shared.saveWorkspace(workspace)
        print("✅ Workspace保存完了")
        
        let appConfig = AppConfiguration(
            workspaceKey: workspace.configurationKey
        )
        AppConfigurationManager.shared.saveConfiguration(appConfig)
        print("✅ AppConfiguration保存完了")
        
        // ロード
        guard let loadedAppConfig = AppConfigurationManager.shared.loadConfiguration() else {
            print("❌ AppConfiguration読み込み失敗")
            return
        }
        print("✅ AppConfiguration読み込み成功")
        
        guard let loadedWorkspace = ConfigurationManager.shared.loadWorkspace(for: loadedAppConfig.workspaceKey) else {
            print("❌ Workspace読み込み失敗")
            return
        }
        print("✅ Workspace読み込み成功")
        
        // 比較
        print("\n【比較】")
        print("元workspaceKey: \(workspace.configurationKey)")
        print("復元workspaceKey: \(loadedWorkspace.configurationKey)")
        print("一致: \(workspace.configurationKey == loadedWorkspace.configurationKey)")
        
        // JSONダンプ
        dumpJSON(loadedWorkspace, title: "Phase 2: 復元されたWorkspace")
        dumpJSON(loadedAppConfig, title: "Phase 2: 復元されたAppConfiguration")
        
        // UserDefaultsの生データ確認
        dumpRawUserDefaults()
    }
    
    static func testCacheAndReferences() {
        print("\n=== Phase 3: キャッシュ・参照確認 ===\n")
        
        guard let workspace = ConfigurationManager.shared.loadOrCreateWorkspace() else {
            print("❌ Workspace読み込み失敗")
            return
        }
        
        // Display参照確認
        if let firstSegment = workspace.displays.first?.passSegments.first {
            print("Display参照: \(firstSegment.display != nil ? \"設定済み\" : \"nil\")")
            print("  displayId: \(firstSegment.displayId)")
            print("  display.id: \(firstSegment.display?.id.uuidString ?? \"nil\")")
            
            // pairedSegment確認
            print("\npairedSegment参照: \(firstSegment.pairedSegment != nil ? \"設定済み\" : \"nil\")")
            print("  pairedSegmentId: \(firstSegment.pairedSegmentId)")
            print("  pairedSegment.id: \(firstSegment.pairedSegment?.id.uuidString ?? \"nil\")")
            
            // デバッグヒント確認
            print("\nデバッグヒント:")
            print("  pairedDisplayId: \(firstSegment.pairedDisplayId?.uuidString ?? \"nil\")")
            print("  pairedDisplayName: \(firstSegment.pairedDisplayName ?? \"nil\")")
            print("  pairedSide: \(firstSegment.pairedSide?.rawValue ?? \"nil\")")
        }
    }
    
    static func dumpJSON<T: Encodable>(_ object: T, title: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(object),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ JSON変換失敗: \(title)")
            return
        }
        
        print("\n【\(title)】")
        print(jsonString)
    }
    
    static func dumpRawUserDefaults() {
        print("\n=== UserDefaults 生データ ===\n")
        
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        let laserKeys = allKeys.filter { $0.hasPrefix("LaserGuide.v2") }.sorted()
        
        for key in laserKeys {
            print("【\(key)】")
            if let data = defaults.data(forKey: key),
               let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
            print("")
        }
    }
}

