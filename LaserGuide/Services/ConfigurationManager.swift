// ConfigurationManager.swift
import Cocoa

/// 設定の保存/読み込みを管理
class ConfigurationManager {
    static let shared = ConfigurationManager()
    
    private let userDefaults = UserDefaults.standard
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calibrationKeyPrefix = "LaserGuide.v2.Configuration."
    
    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Current Display Detection
    
    /// 現在接続されているディスプレイを検出
    func detectCurrentDisplays() -> [Display] {
        let screens = NSScreen.screens
        return screens.map { Display.createDefault(screen: $0) }
    }
    
    /// 現在の設定キーを生成
    func getCurrentConfigurationKey() -> String {
        let screens = NSScreen.screens
        let fingerprints = screens.map { DisplayFingerprint(screen: $0) }
        return generateConfigurationKey(fingerprints: fingerprints)
    }
    
    // MARK: - Configuration Persistence
    
    /// 設定を保存
    func saveConfiguration(_ configuration: WorkspaceConfiguration) {
        var config = configuration
        config.normalize()  // 保存前に正規化
        
        let key = calibrationKeyPrefix + config.configurationKey
        
        do {
            let data = try encoder.encode(config)
            userDefaults.set(data, forKey: key)
            NSLog("✅ 設定を保存: \(config.configurationKey)")
        } catch {
            NSLog("❌ 設定の保存に失敗: \(error)")
        }
    }
    
    /// 設定を読み込み
    func loadConfiguration(for key: String) -> WorkspaceConfiguration? {
        let fullKey = calibrationKeyPrefix + key
        
        guard let data = userDefaults.data(forKey: fullKey) else {
            return nil
        }
        
        do {
            let config = try decoder.decode(WorkspaceConfiguration.self, from: data)
            return config
        } catch {
            NSLog("❌ 設定の読み込みに失敗: \(error)")
            return nil
        }
    }
    
    /// 現在の接続状況に対応する設定を読み込み
    func loadCurrentConfiguration() -> WorkspaceConfiguration? {
        let key = getCurrentConfigurationKey()
        return loadConfiguration(for: key)
    }
    
    /// 設定が存在するかチェック
    func hasConfiguration(for key: String) -> Bool {
        let fullKey = calibrationKeyPrefix + key
        return userDefaults.data(forKey: fullKey) != nil
    }
    
    /// 現在の接続状況に設定が存在するか
    func hasCurrentConfiguration() -> Bool {
        let key = getCurrentConfigurationKey()
        return hasConfiguration(for: key)
    }
    
    /// 設定を削除
    func deleteConfiguration(for key: String) {
        let fullKey = calibrationKeyPrefix + key
        userDefaults.removeObject(forKey: fullKey)
        NSLog("🗑️ 設定を削除: \(key)")
    }
    
    /// すべての設定キーをリスト
    func listAllConfigurationKeys() -> [String] {
        let allKeys = userDefaults.dictionaryRepresentation().keys
        return allKeys
            .filter { $0.hasPrefix(calibrationKeyPrefix) }
            .map { String($0.dropFirst(calibrationKeyPrefix.count)) }
            .sorted()
    }
    
    // MARK: - Workspace Management
    
    /// ワークスペースを読み込み（設定がない場合はデフォルト作成）
    func loadWorkspace() -> Workspace {
        let screens = NSScreen.screens
        
        if let config = loadCurrentConfiguration() {
            NSLog("📂 既存の設定を読み込み: \(config.configurationKey)")
            return Workspace(configuration: config, screens: screens)
        } else {
            NSLog("🆕 デフォルトのワークスペースを作成")
            return Workspace.createDefault(screens: screens)
        }
    }
    
    /// 論理スナップショットを追加して保存
    func saveWithSnapshot(_ configuration: WorkspaceConfiguration, screens: [NSScreen]) {
        var config = configuration
        
        // 各レイアウトに論理スナップショットを追加
        for i in 0..<config.physicalLayouts.count {
            let layout = config.physicalLayouts[i]
            
            // 対応するスクリーンを検索
            if let screen = screens.first(where: {
                DisplayFingerprint(screen: $0) == layout.fingerprint
            }) {
                let snapshot = LogicalSnapshot(
                    frame: screen.frame,
                    isMain: screen == NSScreen.main,
                    localizedName: screen.localizedName,
                    capturedAt: Date(),
                    visibleFrame: screen.visibleFrame
                )
                config.physicalLayouts[i].logicalSnapshot = snapshot
            }
        }
        
        saveConfiguration(config)
    }
    
    // MARK: - Debug
    
    /// デバッグ情報をJSON形式で取得
    func getDebugInfo() -> String? {
        let workspace = loadWorkspace()
        let screens = NSScreen.screens
        
        var debugInfo: [String: Any] = [:]
        
        // アプリバージョン
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            debugInfo["app_version"] = version
        }
        
        // macOSバージョン
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        debugInfo["macos_version"] = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        
        // 現在の設定キー
        debugInfo["current_config_key"] = getCurrentConfigurationKey()
        
        // スクリーン情報
        var screensInfo: [[String: Any]] = []
        for screen in screens {
            var screenInfo: [String: Any] = [:]
            screenInfo["frame"] = [
                "x": screen.frame.origin.x,
                "y": screen.frame.origin.y,
                "width": screen.frame.size.width,
                "height": screen.frame.size.height
            ]
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screenInfo["display_id"] = displayID
            }
            screenInfo["localized_name"] = screen.localizedName
            screenInfo["is_main"] = screen == NSScreen.main
            screensInfo.append(screenInfo)
        }
        debugInfo["screens"] = screensInfo
        
        // ワークスペース情報
        var workspaceInfo: [String: Any] = [:]
        workspaceInfo["display_count"] = workspace.displays.count
        workspaceInfo["edge_count"] = workspace.configuration.navigation.edges.count
        debugInfo["workspace"] = workspaceInfo
        
        // JSON変換
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: debugInfo, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            NSLog("❌ デバッグ情報のJSON変換に失敗: \(error)")
            return nil
        }
    }
    
    /// デバッグ情報をクリップボードにコピー
    func copyDebugInfoToClipboard() {
        guard let jsonString = getDebugInfo() else {
            NSLog("❌ デバッグ情報の取得に失敗")
            return
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)
        NSLog("📋 デバッグ情報をクリップボードにコピーしました")
    }
}

