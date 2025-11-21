#!/usr/bin/env swift

import Cocoa

print("=== Fingerprint 比較（10進 vs 16進） ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    let res = "\(Int(screen.frame.size.width))x\(Int(screen.frame.size.height))"
    let scale = screen.backingScaleFactor != 1.0 ? "@\(Int(screen.backingScaleFactor))x" : ""

    // 10進数版（現在）
    let decimal = "\(vendorID)-\(modelID)-\(serialNumber)_\(res)\(scale)"

    // 16進数版（改善案）
    let vendor = String(format: "%04X", vendorID)
    let model = String(format: "%04X", modelID)
    let serial = String(format: "%08X", serialNumber)
    let hex = "\(vendor)-\(model)-\(serial)_\(res)\(scale)"

    print("--- Screen \(index): \(screen.localizedName) ---")
    print("10進数: \(decimal)")
    print("16進数: \(hex)")
    print("")
}

print("【視認性比較】")
print("10進数:")
print("  1552-41041-4251086178_3456x2234")
print("  7789-40587-480315_3440x1440")
print("  ↑ 桁数がバラバラで揃わない")
print("")
print("16進数:")
print("  0610-A051-FD9E8062_3456x2234")
print("  1E6D-9E8B-00075B3B_3440x1440")
print("  ↑ 固定長16文字で揃う！")
