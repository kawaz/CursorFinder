// DisplayFingerprint.swift
import Cocoa

/// ハードウェア識別子
struct HardwareIdentifier: Codable, Hashable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32

    init(displayID: CGDirectDisplayID) {
        self.vendorID = CGDisplayVendorNumber(displayID)
        self.modelID = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
    }

    init(vendorID: UInt32, modelID: UInt32, serialNumber: UInt32) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
    }

    var stringRepresentation: String {
        // 16進数、8桁固定
        String(format: "%08X%08X%08X", vendorID, modelID, serialNumber)
    }
    
    var vendorIDHex: String {
        String(format: "%08X", vendorID)
    }
    
    var modelIDHex: String {
        String(format: "%08X", modelID)
    }
    
    var serialNumberHex: String {
        String(format: "%08X", serialNumber)
    }
}

/// ディスプレイフィンガープリント（ハードウェア+解像度）
struct DisplayFingerprint: Codable, Hashable {
    let hardwareId: HardwareIdentifier
    let resolution: CGSize      // 論理解像度（points）
    let backingScaleFactor: CGFloat

    init(screen: NSScreen) {
        let deviceDescription = screen.deviceDescription
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

        self.hardwareId = HardwareIdentifier(displayID: displayID)
        self.resolution = screen.frame.size  // フル解像度を使用
        self.backingScaleFactor = screen.backingScaleFactor
    }

    init(hardwareId: HardwareIdentifier, resolution: CGSize, backingScaleFactor: CGFloat) {
        self.hardwareId = hardwareId
        self.resolution = resolution
        self.backingScaleFactor = backingScaleFactor
    }

    /// 文字列表現（設定キー生成用）
    var stringRepresentation: String {
        // ハードウェアID（24文字固定、16進数、ハイフンなし）
        let hw = String(format: "%08X%08X%08X", 
                       hardwareId.vendorID, 
                       hardwareId.modelID, 
                       hardwareId.serialNumber)
        
        // 解像度
        let res = "\(Int(resolution.width))x\(Int(resolution.height))"
        
        // スケール（x統一形式、浮動小数点対応）
        let scale: String
        if backingScaleFactor.truncatingRemainder(dividingBy: 1) == 0 {
            scale = "x\(Int(backingScaleFactor))"
        } else {
            scale = "x\(backingScaleFactor)"
        }
        
        return "\(hw)-\(res)\(scale)"
    }
}

/// 設定キー生成
func generateConfigurationKey(fingerprints: [DisplayFingerprint]) -> String {
    let sorted = fingerprints
        .map { $0.stringRepresentation }
        .sorted()
        .joined(separator: "_")  // アンダーバーで連結（URL/ファイル名安全）
    return "config_\(sorted)"
}
