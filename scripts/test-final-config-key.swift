#!/usr/bin/env swift

import Cocoa

print("=== 最終的な設定キー形式 ===\n")

let screens = NSScreen.screens
var fingerprints: [String] = []

for screen in screens {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    // ハードウェアID（24文字固定、ハイフンなし）
    let hw = String(format: "%08X%08X%08X", vendorID, modelID, serialNumber)

    // 解像度
    let res = "\(Int(screen.frame.size.width))x\(Int(screen.frame.size.height))"

    // スケール（x統一形式）
    let scaleStr: String
    if screen.backingScaleFactor.truncatingRemainder(dividingBy: 1) == 0 {
        scaleStr = "x\(Int(screen.backingScaleFactor))"
    } else {
        scaleStr = "x\(screen.backingScaleFactor)"
    }

    // フィンガープリント（ハイフンで区切り）
    let fingerprint = "\(hw)-\(res)\(scaleStr)"
    fingerprints.append(fingerprint)

    print("Display: \(screen.localizedName)")
    print("  Fingerprint: \(fingerprint)")
    print("    Hardware: \(hw) (24文字)")
    print("    Resolution: \(res)\(scaleStr)")
    print("")
}

// 設定キー生成（アンダーバーで連結）
let configKey = "config_" + fingerprints.sorted().joined(separator: "_")

print("【設定キー】")
print(configKey)
print("")
print("【特徴】")
print("- URL安全: +記号なし")
print("- ファイル名安全: エスケープ不要")
print("- 固定長: 各fingerprint = 24文字 + ハイフン + 解像度")
print("- 分割可能: アンダーバーで split")
print("")
print("【分割例】")
let parts = configKey.replacingOccurrences(of: "config_", with: "").split(separator: "_")
for (i, part) in parts.enumerated() {
    print("  Display \(i): \(part)")
}
