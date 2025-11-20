// AppSettings.swift
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

/// アプリ設定
struct AppSettings: Codable {
    var forceBlockModifiers: ModifierKeySet = .option
    var forceBlockEnabled: Bool = true
    
    // 将来の拡張用
    var laserColor: String = "blue"
    var laserWidth: Double = 8.0
    var inactivityThreshold: Double = 0.3
    
    private enum CodingKeys: String, CodingKey {
        case forceBlockModifiers
        case forceBlockEnabled
        case laserColor
        case laserWidth
        case inactivityThreshold
    }
}

/// アプリ設定マネージャー
class AppSettingsManager {
    static let shared = AppSettingsManager()
    
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "LaserGuide.v2.AppSettings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {}
    
    /// 設定を読み込み
    func loadSettings() -> AppSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()  // デフォルト
        }
        return settings
    }
    
    /// 設定を保存
    func saveSettings(_ settings: AppSettings) {
        guard let data = try? encoder.encode(settings) else {
            NSLog("❌ 設定の保存に失敗")
            return
        }
        userDefaults.set(data, forKey: settingsKey)
    }
}

