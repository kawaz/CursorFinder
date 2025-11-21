#!/usr/bin/env swift

import Cocoa

print("=== NSScreen で取得可能な全プロパティ ===\n")

guard let screen = NSScreen.main else {
    print("メインスクリーンが見つかりません")
    exit(1)
}

let deviceDescription = screen.deviceDescription
let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

print("【基本情報】")
print("frame: \(screen.frame)")
print("visibleFrame: \(screen.visibleFrame)")
print("localizedName: \(screen.localizedName)")

print("\n【解像度・スケール】")
print("backingScaleFactor: \(screen.backingScaleFactor)")
print("deviceDescription[NSDeviceResolution]: \(deviceDescription[NSDeviceDescriptionKey("NSDeviceResolution")] ?? "N/A")")
print("deviceDescription[NSDeviceSize]: \(deviceDescription[NSDeviceDescriptionKey("NSDeviceSize")] ?? "N/A")")

print("\n【色情報】")
print("depth: \(screen.depth)")
print("colorSpace: \(screen.colorSpace?.localizedName ?? "N/A")")
print("deviceDescription[NSDeviceColorSpaceName]: \(deviceDescription[NSDeviceDescriptionKey("NSDeviceColorSpaceName")] ?? "N/A")")
print("deviceDescription[NSDeviceBitsPerSample]: \(deviceDescription[NSDeviceDescriptionKey("NSDeviceBitsPerSample")] ?? "N/A")")

print("\n【HDR・拡張色域】")
print("maximumExtendedDynamicRangeColorComponentValue: \(screen.maximumExtendedDynamicRangeColorComponentValue)")
print("maximumPotentialExtendedDynamicRangeColorComponentValue: \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
print("maximumReferenceExtendedDynamicRangeColorComponentValue: \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")

print("\n【リフレッシュレート】")
if let mode = CGDisplayCopyDisplayMode(displayID) {
    print("refreshRate: \(mode.refreshRate) Hz")
} else {
    print("refreshRate: 取得不可")
}

print("\n【その他】")
print("safeAreaInsets: \(screen.safeAreaInsets)")
print("auxiliaryTopLeftArea: \(screen.auxiliaryTopLeftArea ?? .zero)")
print("auxiliaryTopRightArea: \(screen.auxiliaryTopRightArea ?? .zero)")

print("\n【deviceDescription 全キー】")
for (key, value) in deviceDescription.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    print("\(key.rawValue): \(value)")
}
