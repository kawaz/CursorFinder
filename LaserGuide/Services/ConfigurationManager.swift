// ConfigurationManager.swift
import Cocoa
import Metal

/// 設定の保存/読み込みを管理
class ConfigurationManager {
    static let shared = ConfigurationManager()

    private let userDefaults = UserDefaults.standard
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let workspaceKeyPrefix = "LaserGuide.v2.Workspace."

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
        return screens.map { Display.create(from: $0) }
    }

    /// 現在の設定キーを生成
    func getCurrentConfigurationKey() -> String {
        let screens = NSScreen.screens
        let fingerprints = screens.map { DisplayFingerprint(screen: $0) }
        return generateConfigurationKey(fingerprints: fingerprints)
    }

    // MARK: - Workspace Configuration Persistence

    /// Workspace設定を保存
    func saveWorkspace(_ configuration: WorkspaceConfiguration) {
        var config = configuration
        config.normalize()  // 保存前に正規化
        config.metadata.modified = Date()  // 更新日時を設定

        let key = workspaceKeyPrefix + config.configurationKey

        do {
            let data = try encoder.encode(config)
            userDefaults.set(data, forKey: key)
            NSLog("✅ Workspace設定を保存: \(config.configurationKey)")
        } catch {
            NSLog("❌ Workspace設定の保存に失敗: \(error)")
        }
    }

    /// Workspace設定を読み込み
    func loadWorkspace(for key: String) -> WorkspaceConfiguration? {
        let fullKey = workspaceKeyPrefix + key

        guard let data = userDefaults.data(forKey: fullKey) else {
            return nil
        }

        do {
            var config = try decoder.decode(WorkspaceConfiguration.self, from: data)

            // 読み込み後の初期化（Display参照とペアリング設定）
            config.initialize()

            return config
        } catch {
            NSLog("❌ Workspace設定の読み込みに失敗: \(error)")
            return nil
        }
    }

    /// 現在の接続状況に対応するWorkspace設定を読み込み
    func loadCurrentWorkspace() -> WorkspaceConfiguration? {
        let key = getCurrentConfigurationKey()
        return loadWorkspace(for: key)
    }

    /// Workspace設定が存在するかチェック
    func hasWorkspace(for key: String) -> Bool {
        let fullKey = workspaceKeyPrefix + key
        return userDefaults.data(forKey: fullKey) != nil
    }

    /// 現在の接続状況にWorkspace設定が存在するか
    func hasCurrentWorkspace() -> Bool {
        let key = getCurrentConfigurationKey()
        return hasWorkspace(for: key)
    }

    /// Workspace設定を削除
    func deleteWorkspace(for key: String) {
        let fullKey = workspaceKeyPrefix + key
        userDefaults.removeObject(forKey: fullKey)
        NSLog("🗑️ Workspace設定を削除: \(key)")
    }

    /// すべてのWorkspace設定キーをリスト
    func listAllWorkspaceKeys() -> [String] {
        let allKeys = userDefaults.dictionaryRepresentation().keys
        return allKeys
            .filter { $0.hasPrefix(workspaceKeyPrefix) }
            .map { String($0.dropFirst(workspaceKeyPrefix.count)) }
            .sorted()
    }

    // MARK: - Workspace Management

    /// Workspace設定を読み込み（設定がない場合はデフォルト作成）
    func loadOrCreateWorkspace() -> WorkspaceConfiguration {
        if let config = loadCurrentWorkspace() {
            NSLog("📂 既存のWorkspace設定を読み込み: \(config.configurationKey)")

            // 現在のスクリーン情報とマージ（論理座標を更新）
            let merged = mergeWithCurrentScreens(config)
            
            // マージ後の設定を保存（論理座標の更新を反映）
            saveWorkspace(merged)
            
            return merged
        } else {
            NSLog("🆕 デフォルトのWorkspace設定を作成")
            let screens = NSScreen.screens
            let newConfig = WorkspaceConfiguration.createDefault(screens: screens)
            
            // 新規作成した設定を自動保存
            saveWorkspace(newConfig)
            
            return newConfig
        }
    }

    /// 保存された設定と現在のスクリーン情報をマージ
    private func mergeWithCurrentScreens(_ config: WorkspaceConfiguration) -> WorkspaceConfiguration {
        let screens = NSScreen.screens
        var updatedDisplays: [Display] = []

        for display in config.displays {
            // 対応するNSScreenを検索
            guard let screen = screens.first(where: {
                let fingerprint = DisplayFingerprint(screen: $0)
                return fingerprint.stringRepresentation == display.hardware.fingerprint
            }) else {
                // 対応するスクリーンが見つからない（ディスプレイが外されている）
                continue
            }

            // 論理座標のみ更新
            var updated = display
            updated.coordinates.logical = createLogicalFrame(from: screen)
            updatedDisplays.append(updated)
        }

        var merged = config
        merged.displays = updatedDisplays
        merged.initialize()  // 初期化
        return merged
    }

    /// NSScreenから論理座標フレームを作成
    private func createLogicalFrame(from screen: NSScreen) -> Display.CoordinateFrame {
        Display.CoordinateFrame(
            position: CGPoint(x: screen.frame.minX, y: screen.frame.minY),
            size: screen.frame.size,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: Display.CoordinateInsets(screen.safeAreaInsets)
        )
    }

    // MARK: - Debug

    /// デバッグ情報を生成
    func generateDebugInfo() -> [String: Any] {
        var debugInfo: [String: Any] = [:]

        // システム情報
        let systemInfo = SystemMetadata.current()
        debugInfo["system"] = systemInfo.toDictionary()

        // 現在のWorkspace設定
        let workspace = loadOrCreateWorkspace()
        if let data = try? encoder.encode(workspace),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            debugInfo["configuration"] = dict
        }

        // AppConfiguration
        if let appConfig = AppConfigurationManager.shared.loadConfiguration() {
            if let data = try? encoder.encode(appConfig),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                debugInfo["appConfiguration"] = dict
            }
        }

        return debugInfo
    }

    /// デバッグ情報をJSON文字列で取得
    func getDebugJSON() -> String? {
        let debugInfo = generateDebugInfo()

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
        guard let jsonString = getDebugJSON() else {
            NSLog("❌ デバッグ情報の取得に失敗")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)
        NSLog("📋 デバッグ情報をクリップボードにコピーしました")
    }
}

// MARK: - System Metadata

/// システムメタデータ（デバッグ用、設定ファイルには保存しない）
struct SystemMetadata {
    let osVersion: String
    let osBuildNumber: String?
    let hardwareModel: String
    let cpuBrand: String
    let cpuPhysicalCores: Int
    let cpuLogicalCores: Int
    let memoryGB: Int
    let gpus: [GPUInfo]
    let capturedAt: Date

    struct GPUInfo {
        let name: String
        let isLowPower: Bool
        let isRemovable: Bool
        let recommendedMaxWorkingSetGB: Int
    }

    /// 現在のシステム情報を取得
    static func current() -> SystemMetadata {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion

        // ハードウェアモデル
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let hardwareModel = String(cString: model)

        // CPU情報
        var cpuBrandSize = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &cpuBrandSize, nil, 0)
        var cpuBrand = [CChar](repeating: 0, count: cpuBrandSize)
        sysctlbyname("machdep.cpu.brand_string", &cpuBrand, &cpuBrandSize, nil, 0)
        let cpuBrandString = String(cString: cpuBrand)

        var physicalCPU: Int = 0
        var physicalCPUSize = MemoryLayout<Int>.size
        sysctlbyname("hw.physicalcpu", &physicalCPU, &physicalCPUSize, nil, 0)

        var logicalCPU: Int = 0
        var logicalCPUSize = MemoryLayout<Int>.size
        sysctlbyname("hw.logicalcpu", &logicalCPU, &logicalCPUSize, nil, 0)

        // メモリ
        var memSize: UInt64 = 0
        var memSizeSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeSize, nil, 0)
        let memoryGB = Int(memSize / (1024 * 1024 * 1024))

        // GPU情報
        var gpus: [GPUInfo] = []
        let devices = MTLCopyAllDevices()
        for device in devices {
            let gpu = GPUInfo(
                name: device.name,
                isLowPower: device.isLowPower,
                isRemovable: device.isRemovable,
                recommendedMaxWorkingSetGB: Int(device.recommendedMaxWorkingSetSize / (1024 * 1024 * 1024))
            )
            gpus.append(gpu)
        }

        return SystemMetadata(
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            osBuildNumber: nil,  // TODO: 取得方法を調査
            hardwareModel: hardwareModel,
            cpuBrand: cpuBrandString,
            cpuPhysicalCores: physicalCPU,
            cpuLogicalCores: logicalCPU,
            memoryGB: memoryGB,
            gpus: gpus,
            capturedAt: Date()
        )
    }

    /// 辞書に変換（JSONシリアライズ用）
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["osVersion"] = osVersion
        dict["osBuildNumber"] = osBuildNumber
        dict["hardwareModel"] = hardwareModel
        dict["cpuBrand"] = cpuBrand
        dict["cpuPhysicalCores"] = cpuPhysicalCores
        dict["cpuLogicalCores"] = cpuLogicalCores
        dict["memoryGB"] = memoryGB
        dict["gpus"] = gpus.map { [
            "name": $0.name,
            "isLowPower": $0.isLowPower,
            "isRemovable": $0.isRemovable,
            "recommendedMaxWorkingSetGB": $0.recommendedMaxWorkingSetGB
        ]}
        dict["capturedAt"] = ISO8601DateFormatter().string(from: capturedAt)
        return dict
    }
}

// MARK: - WorkspaceConfiguration Dictionary Conversion

extension WorkspaceConfiguration {
    /// 辞書に変換（デバッグ用）
    func toDictionary() -> [String: Any] {
        do {
            let data = try JSONEncoder().encode(self)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
        } catch {
            NSLog("❌ WorkspaceConfiguration の辞書変換に失敗: \(error)")
        }
        return [:]
    }
}
