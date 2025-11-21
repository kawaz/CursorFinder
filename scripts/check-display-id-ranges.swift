#!/usr/bin/env swift

import Cocoa

print("=== Display ID の実際の値と範囲 ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    print("--- Screen \(index): \(screen.localizedName) ---")
    print("vendorID:")
    print("  UInt32値: \(vendorID)")
    print("  16進数:   0x\(String(format: "%08X", vendorID))")
    print("  必要桁数: \(String(vendorID, radix: 16, uppercase: true).count)桁")
    print("  UInt16範囲内: \(vendorID <= UInt32(UInt16.max))")

    print("modelID:")
    print("  UInt32値: \(modelID)")
    print("  16進数:   0x\(String(format: "%08X", modelID))")
    print("  必要桁数: \(String(modelID, radix: 16, uppercase: true).count)桁")
    print("  UInt16範囲内: \(modelID <= UInt32(UInt16.max))")

    print("serialNumber:")
    print("  UInt32値: \(serialNumber)")
    print("  16進数:   0x\(String(format: "%08X", serialNumber))")
    print("  必要桁数: \(String(serialNumber, radix: 16, uppercase: true).count)桁")
    print("  UInt16範囲内: \(serialNumber <= UInt32(UInt16.max))")

    print("")
}

print("【結論】")
print("- vendorID/modelID は実質UInt16範囲（0x0000〜0xFFFF）")
print("- serialNumber は UInt32の全範囲を使用")
print("")
print("【推奨フォーマット】")
print("- vendorID:     %04X (4桁)")
print("- modelID:      %04X (4桁)")
print("- serialNumber: %08X (8桁)")
print("- 合計: 16文字（ハイフン除く）")
