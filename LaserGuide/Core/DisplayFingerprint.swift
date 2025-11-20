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
        "\(vendorID)-\(modelID)-\(serialNumber)"
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
        let hw = hardwareId.stringRepresentation
        let res = "\(Int(resolution.width))x\(Int(resolution.height))"
        let scale = backingScaleFactor != 1.0 ? "@\(Int(backingScaleFactor))x" : ""
        return "\(hw)_\(res)\(scale)"
    }
}

/// 設定キー生成
func generateConfigurationKey(fingerprints: [DisplayFingerprint]) -> String {
    let sorted = fingerprints
        .map { $0.stringRepresentation }
        .sorted()
        .joined(separator: "+")
    return "config_\(sorted)"
}
