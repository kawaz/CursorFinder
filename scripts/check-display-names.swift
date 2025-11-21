#!/usr/bin/env swift

import Cocoa

print("=== NSScreen Display Name Information ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    print("--- Screen \(index) ---")

    // localizedName (これがNSScreenで取得できる主な名前)
    print("localizedName: \(screen.localizedName)")

    // deviceDescription から取得できる情報
    let deviceDescription = screen.deviceDescription
    print("deviceDescription keys: \(deviceDescription.keys)")

    if let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        print("Display ID: \(displayID)")

        // Built-in かどうか
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        print("Is Built-in: \(isBuiltIn)")
    }

    print("")
}

print("\n=== 結論 ===")
print("NSScreenからは localizedName しか取得できません。")
print("「非ローカライズ名」に相当するAPIは存在しません。")
print("より詳細な情報が必要な場合は IOKit を使う必要があります。")
