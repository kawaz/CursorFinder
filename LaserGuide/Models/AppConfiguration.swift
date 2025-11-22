// AppConfiguration.swift
import Cocoa

/// 修飾キーセット（組み合わせ可能）
struct ModifierKeySet: Codable, Hashable {
    var shift: Bool = false
    var control: Bool = false
    var option: Bool = false
    var command: Bool = false
    
    /// NSEvent.ModifierFlagsから生成
    init(from flags: NSEvent.ModifierFlags) {
        self.shift = flags.contains(.shift)
        self.control = flags.contains(.control)
        self.option = flags.contains(.option)
        self.command = flags.contains(.command)
    }
    
    init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
    }
    
    /// 空のセット（修飾キーなし）
    static var none: ModifierKeySet {
        ModifierKeySet()
    }
    
    /// プリセット
    static var option: ModifierKeySet {
        ModifierKeySet(option: true)
    }
    
    static var commandShift: ModifierKeySet {
        ModifierKeySet(shift: true, command: true)
    }
    
    /// 現在の修飾キーと一致するかチェック
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        return shift == flags.contains(.shift) &&
               control == flags.contains(.control) &&
               option == flags.contains(.option) &&
               command == flags.contains(.command)
    }
    
    /// 人間が読める文字列
    var displayString: String {
        var keys: [String] = []
        if control { keys.append("⌃") }
        if option { keys.append("⌥") }
        if shift { keys.append("⇧") }
        if command { keys.append("⌘") }
        return keys.isEmpty ? "なし" : keys.joined()
    }
}

/// アプリ設定（グローバル）
struct AppConfiguration: Codable {
    var workspaceKey: String
    
    // 機能設定
    var laser: LaserConfiguration
    var edgeNavigation: EdgeNavigationConfiguration
    
    // その他
    var autoLaunchEnabled: Bool = false
    
    // 実行時キャッシュ（private → JSON保存から除外）
    private var _workspace: WorkspaceConfiguration?
    
    var workspace: WorkspaceConfiguration? {
        get { _workspace }
        set {
            _workspace = newValue
            if let ws = newValue {
                self.workspaceKey = ws.configurationKey
            }
        }
    }
    
    /// レーザー表示機能の設定
    struct LaserConfiguration: Codable {
        var enabled: Bool = true
        
        // 外観
        var color: LaserColor = .blue
        var width: Double = 8.0
        var opacity: Double = 0.3
        
        // 動作
        var inactivityThreshold: Double = 0.3  // 秒
        var showOnAllDisplays: Bool = true
        
        enum LaserColor: String, Codable {
            case blue, red, green, purple, cyan, custom
        }
    }
    
    /// エッジナビゲーション機能の設定
    struct EdgeNavigationConfiguration: Codable {
        var enabled: Bool = true
        
        // 強制Block
        var forceBlockEnabled: Bool = true
        var forceBlockModifiers: ModifierKeySet = .option
    }
    
    init(
        workspaceKey: String,
        laser: LaserConfiguration = LaserConfiguration(),
        edgeNavigation: EdgeNavigationConfiguration = EdgeNavigationConfiguration(),
        autoLaunchEnabled: Bool = false
    ) {
        self.workspaceKey = workspaceKey
        self.laser = laser
        self.edgeNavigation = edgeNavigation
        self.autoLaunchEnabled = autoLaunchEnabled
    }
}

/// アプリ設定マネージャー
class AppConfigurationManager {
    static let shared = AppConfigurationManager()
    
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "LaserGuide.v2.AppConfiguration"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }
    
    /// 設定を読み込み
    func loadConfiguration() -> AppConfiguration? {
        guard let data = userDefaults.data(forKey: settingsKey) else {
            return nil
        }
        
        do {
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            NSLog("❌ AppConfiguration の読み込みに失敗: \(error)")
            return nil
        }
    }
    
    /// 設定を読み込み（存在しない場合はデフォルト作成・保存）
    func loadOrCreateConfiguration(workspaceKey: String) -> AppConfiguration {
        if let config = loadConfiguration() {
            NSLog("📂 既存のAppConfiguration を読み込み")
            return config
        } else {
            NSLog("🆕 デフォルトのAppConfiguration を作成")
            let newConfig = getDefaultConfiguration(workspaceKey: workspaceKey)
            saveConfiguration(newConfig)
            return newConfig
        }
    }
    
    /// 設定を保存
    func saveConfiguration(_ config: AppConfiguration) {
        do {
            let data = try encoder.encode(config)
            userDefaults.set(data, forKey: settingsKey)
        } catch {
            NSLog("❌ AppConfiguration の保存に失敗: \(error)")
        }
    }
    
    /// デフォルト設定を取得
    func getDefaultConfiguration(workspaceKey: String) -> AppConfiguration {
        AppConfiguration(workspaceKey: workspaceKey)
    }
}
