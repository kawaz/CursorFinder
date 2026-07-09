#!/usr/bin/env swift
//
// DR-0005 / DR-0006 検証: 接続中の全ディスプレイについて、
// CGDisplayBounds (CG, y-down) と NSScreen.frame (y-up) の関係、
// CGDisplayScreenSize (mm) の取得可否、backingScaleFactor、
// serial/vendor/model 番号をダンプする。
//
// 実行: swift scripts/verify/dump-displays.swift
// 権限: 不要 (CGDisplay系・NSScreen系は通常の読み取り専用 API)
//

import Cocoa
import CoreGraphics

print("=== ディスプレイ情報ダンプ (DR-0005 / DR-0006 検証) ===\n")

var displayCount: UInt32 = 0
let maxDisplays: UInt32 = 16
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))

let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
guard result == .success else {
    print("CGGetActiveDisplayList 失敗: \(result)")
    exit(1)
}

print("アクティブディスプレイ数: \(displayCount)\n")

// NSScreen 側は screenNumber (= CGDirectDisplayID) で対応する CGDisplayID に紐付ける
func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
    for screen in NSScreen.screens {
        let deviceDescription = screen.deviceDescription
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           screenNumber == displayID {
            return screen
        }
    }
    return nil
}

for i in 0..<Int(displayCount) {
    let displayID = displayIDs[i]
    print("--- ディスプレイ #\(i) (CGDirectDisplayID = \(displayID)) ---")

    // CG座標系 (top-left原点, y-down)
    let cgBounds = CGDisplayBounds(displayID)
    print("CGDisplayBounds (CG, y-down想定): origin=(\(cgBounds.origin.x), \(cgBounds.origin.y)), size=(\(cgBounds.size.width), \(cgBounds.size.height))")

    let isMain = CGDisplayIsMain(displayID) != 0
    print("CGDisplayIsMain: \(isMain)")

    // NSScreen座標系 (bottom-left原点, y-up)
    if let screen = nsScreen(for: displayID) {
        let frame = screen.frame
        print("NSScreen.frame (y-up想定): origin=(\(frame.origin.x), \(frame.origin.y)), size=(\(frame.size.width), \(frame.size.height))")
        print("NSScreen.backingScaleFactor: \(screen.backingScaleFactor)")
        print("NSScreen.localizedName: \(screen.localizedName)")
    } else {
        print("NSScreen: 対応する screen が見つかりません")
    }

    // 物理サイズ (mm)
    let physicalSize = CGDisplayScreenSize(displayID)
    print("CGDisplayScreenSize (mm): width=\(physicalSize.width), height=\(physicalSize.height)")

    // ピクセルサイズ (現在のモード)
    let pixelWidth = CGDisplayPixelsWide(displayID)
    let pixelHeight = CGDisplayPixelsHigh(displayID)
    print("CGDisplayPixelsWide/High (px): \(pixelWidth) x \(pixelHeight)")

    if physicalSize.width > 0 {
        let dpmm = Double(pixelWidth) / physicalSize.width
        let dpi = dpmm * 25.4
        print("導出 DPI (px幅 / mm幅 * 25.4): \(dpi)")
    } else {
        print("導出 DPI: 計算不可 (physicalSize.width == 0)")
    }

    // 識別子系
    let vendor = CGDisplayVendorNumber(displayID)
    let model = CGDisplayModelNumber(displayID)
    let serial = CGDisplaySerialNumber(displayID)
    let unit = CGDisplayUnitNumber(displayID)
    print("CGDisplayVendorNumber: \(vendor) (0x\(String(vendor, radix: 16)))")
    print("CGDisplayModelNumber: \(model) (0x\(String(model, radix: 16)))")
    print("CGDisplaySerialNumber: \(serial)")
    print("CGDisplayUnitNumber: \(unit)")

    print("")
}

// NSScreen.screens の総数と CG の総数が一致するかも確認 (ミラーリング時に不一致になりうる)
print("--- 突合確認 ---")
print("NSScreen.screens.count: \(NSScreen.screens.count)")
print("CGGetActiveDisplayList count: \(displayCount)")

// NSScreen 側から見た y-up/y-down 関係の理論値確認:
// 全ディスプレイの NSScreen.frame の union の高さを基準に、
// 各ディスプレイの CG y と NSScreen y の変換式 (cgY = totalHeight - nsY - height) が
// 成立するかを比較する。totalHeight は「main ディスプレイの高さ」を使うのが
// macOS の一般的な変換式 (NSScreen 全体の origin は main の左下が (0,0))。
if let mainScreen = NSScreen.screens.first(where: { screen in
    let dd = screen.deviceDescription
    if let num = dd[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        return CGDisplayIsMain(num) != 0
    }
    return false
}) {
    let mainHeight = mainScreen.frame.height
    print("\nmain ディスプレイの NSScreen.frame.height: \(mainHeight) (y変換の基準値)")
    for i in 0..<Int(displayCount) {
        let displayID = displayIDs[i]
        guard let screen = nsScreen(for: displayID) else { continue }
        let cgBounds = CGDisplayBounds(displayID)
        let nsFrame = screen.frame
        // 理論変換式: cgY = mainHeight - nsY - height
        let predictedCgY = mainHeight - nsFrame.origin.y - nsFrame.height
        let match = abs(predictedCgY - cgBounds.origin.y) < 0.5
        print("ディスプレイ#\(i): 実測 CG.y=\(cgBounds.origin.y), 予測値 (mainHeight - nsY - height)=\(predictedCgY), 一致=\(match)")
    }
}
