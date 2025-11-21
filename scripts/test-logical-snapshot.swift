#!/usr/bin/env swift

import Cocoa

struct EdgeInsets: Codable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    init(_ insets: NSEdgeInsets) {
        self.top = insets.top
        self.left = insets.left
        self.bottom = insets.bottom
        self.right = insets.right
    }
}

struct DisplayMetadata: Codable {
    // フィンガープリント
    let fingerprintString: String

    // ハードウェア識別
    let displayID: UInt32
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32

    // 論理座標情報
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: EdgeInsets

    // ディスプレイ状態
    let isMain: Bool
    let isBuiltIn: Bool

    // 名前
    let localizedName: String

    // 解像度・スケール
    let backingScaleFactor: CGFloat
    let pointsResolution: CGSize
    let pixelsResolution: CGSize

    // 物理サイズ
    let physicalSizeMM: CGSize
    let calculatedPPI: Double

    // リフレッシュレート
    let refreshRate: Double

    // 色空間・色深度
    let colorSpaceName: String?
    let colorSpaceLocalizedName: String?
    let bitsPerSample: Int?
    let colorDepth: Int

    // HDR対応
    let maxHDRColorValue: CGFloat
    let maxPotentialHDRColorValue: CGFloat
    let maxReferenceHDRColorValue: CGFloat

    // タイムスタンプ
    let capturedAt: Date
}

print("=== LogicalSnapshot Test ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    print("--- Screen \(index) ---")

    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    // 物理サイズとPPIを計算
    let physicalSize = CGDisplayScreenSize(displayID)
    let pixelWidth = screen.frame.size.width * screen.backingScaleFactor
    let calculatedPPI = physicalSize.width > 0 ? pixelWidth / (physicalSize.width / 25.4) : 0

    // フィンガープリントを生成
    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)
    let hw = "\(vendorID)-\(modelID)-\(serialNumber)"
    let res = "\(Int(screen.frame.size.width))x\(Int(screen.frame.size.height))"
    let scale = screen.backingScaleFactor != 1.0 ? "@\(Int(screen.backingScaleFactor))x" : ""
    let fingerprintString = "\(hw)_\(res)\(scale)"

    // リフレッシュレートを取得
    let refreshRate: Double
    if let mode = CGDisplayCopyDisplayMode(displayID) {
        refreshRate = mode.refreshRate
    } else {
        refreshRate = 0
    }

    // DisplayMetadataを作成
    let snapshot = DisplayMetadata(
        fingerprintString: fingerprintString,
        displayID: displayID,
        vendorID: vendorID,
        modelID: modelID,
        serialNumber: serialNumber,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame,
        safeAreaInsets: EdgeInsets(screen.safeAreaInsets),
        isMain: screen == NSScreen.main,
        isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
        localizedName: screen.localizedName,
        backingScaleFactor: screen.backingScaleFactor,
        pointsResolution: screen.frame.size,
        pixelsResolution: CGSize(
            width: screen.frame.size.width * screen.backingScaleFactor,
            height: screen.frame.size.height * screen.backingScaleFactor
        ),
        physicalSizeMM: physicalSize,
        calculatedPPI: calculatedPPI,
        refreshRate: refreshRate,
        colorSpaceName: deviceDescription[NSDeviceDescriptionKey("NSDeviceColorSpaceName")] as? String,
        colorSpaceLocalizedName: screen.colorSpace?.localizedName,
        bitsPerSample: deviceDescription[NSDeviceDescriptionKey("NSDeviceBitsPerSample")] as? Int,
        colorDepth: Int(screen.depth.rawValue),
        maxHDRColorValue: screen.maximumExtendedDynamicRangeColorComponentValue,
        maxPotentialHDRColorValue: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
        maxReferenceHDRColorValue: screen.maximumReferenceExtendedDynamicRangeColorComponentValue,
        capturedAt: Date()
    )

    // JSON出力
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if let jsonData = try? encoder.encode(snapshot),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }

    print("")
}
