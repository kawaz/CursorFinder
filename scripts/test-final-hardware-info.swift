#!/usr/bin/env swift

import Cocoa

struct HardwareInfo: Codable {
    let fingerprint: String
    let displayID: UInt32
    let vendorID: UInt32
    let vendorIDHex: String
    let modelID: UInt32
    let modelIDHex: String
    let serialNumber: UInt32
    let serialNumberHex: String
}

print("=== HardwareInfo 最終形式 ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    // 16進数表現（全て8桁固定）
    let vendorHex = String(format: "%08X", vendorID)
    let modelHex = String(format: "%08X", modelID)
    let serialHex = String(format: "%08X", serialNumber)

    // フィンガープリント（ハイフンなし）
    let res = "\(Int(screen.frame.size.width))x\(Int(screen.frame.size.height))"
    let scale = screen.backingScaleFactor != 1.0 ? "@\(Int(screen.backingScaleFactor))x" : ""
    let fingerprint = "\(vendorHex)\(modelHex)\(serialHex)_\(res)\(scale)"

    let hardwareInfo = HardwareInfo(
        fingerprint: fingerprint,
        displayID: displayID,
        vendorID: vendorID,
        vendorIDHex: vendorHex,
        modelID: modelID,
        modelIDHex: modelHex,
        serialNumber: serialNumber,
        serialNumberHex: serialHex
    )

    print("--- Screen \(index): \(screen.localizedName) ---")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if let jsonData = try? encoder.encode(hardwareInfo),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }

    print("")
}

print("【設定キー例】")
print("config_000006100000A051FD626D62_3456x2234+00001E6D00009E8B0007543B_3440x1440")
print("       ^^^^^^^^^^^^^^^^^^^^^^^^              ^^^^^^^^^^^^^^^^^^^^^^^^")
print("       固定24文字                             固定24文字")
