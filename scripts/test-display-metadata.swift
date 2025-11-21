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

    init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    static var zero: EdgeInsets {
        EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct DisplayMetadata: Codable {
    let fingerprint: String
    let hardware: HardwareInfo
    let coordinates: CoordinatesInfo
    let display: DisplayInfo
    let visual: VisualInfo
    let capturedAt: Date

    struct HardwareInfo: Codable {
        let displayID: UInt32
        let vendorID: UInt32
        let modelID: UInt32
        let serialNumber: UInt32
    }

    struct CoordinatesInfo: Codable {
        let logical: LogicalFrame
        let physical: PhysicalFrame
    }

    struct LogicalFrame: Codable {
        let position: CGPoint
        let size: CGSize
        let visibleFrame: CGRect
        let safeAreaInsets: EdgeInsets
    }

    struct PhysicalFrame: Codable {
        let position: CGPoint
        let size: CGSize
        let visibleFrame: CGRect
        let safeAreaInsets: EdgeInsets
    }

    struct DisplayInfo: Codable {
        let isMain: Bool
        let isBuiltIn: Bool
        let name: String
        let resolution: ResolutionInfo
        let refreshRate: Double
    }

    struct ResolutionInfo: Codable {
        let points: CGSize
        let pixels: CGSize
        let backingScaleFactor: CGFloat
        let ppi: Double
    }

    struct VisualInfo: Codable {
        let colorSpaceName: String?
        let colorSpaceLocalizedName: String?
        let bitsPerSample: Int?
        let colorDepth: Int
        let hdrMaxValue: CGFloat
        let hdrMaxPotentialValue: CGFloat
        let hdrMaxReferenceValue: CGFloat
    }
}

print("=== DisplayMetadata Test (階層化版) ===\n")

let screens = NSScreen.screens

for (index, screen) in screens.enumerated() {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    // ハードウェア情報
    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    // フィンガープリント文字列
    let hw = "\(vendorID)-\(modelID)-\(serialNumber)"
    let res = "\(Int(screen.frame.size.width))x\(Int(screen.frame.size.height))"
    let scale = screen.backingScaleFactor != 1.0 ? "@\(Int(screen.backingScaleFactor))x" : ""
    let fingerprintString = "\(hw)_\(res)\(scale)"

    // 物理サイズとPPI
    let physicalSize = CGDisplayScreenSize(displayID)
    let pixelWidth = screen.frame.size.width * screen.backingScaleFactor
    let calculatedPPI = physicalSize.width > 0 ? pixelWidth / (physicalSize.width / 25.4) : 0

    // リフレッシュレート
    let refreshRate: Double
    if let mode = CGDisplayCopyDisplayMode(displayID) {
        refreshRate = mode.refreshRate
    } else {
        refreshRate = 0
    }

    // 物理座標のvisibleFrameとsafeAreaInsetsを補完
    let frame = screen.frame
    let visibleFrame = screen.visibleFrame
    let safeAreaInsets = screen.safeAreaInsets

    // 物理座標の位置（仮に0,0として）
    let physicalPosition = CGPoint(x: 0, y: 0)

    // visibleFrameを物理座標に変換
    let physicalVisibleFrame = CGRect(
        x: physicalPosition.x + (visibleFrame.minX - frame.minX) / frame.width * physicalSize.width,
        y: physicalPosition.y + (visibleFrame.minY - frame.minY) / frame.height * physicalSize.height,
        width: visibleFrame.width / frame.width * physicalSize.width,
        height: visibleFrame.height / frame.height * physicalSize.height
    )

    // safeAreaInsetsを物理座標に変換
    let physicalSafeAreaInsets = EdgeInsets(
        top: safeAreaInsets.top / frame.height * physicalSize.height,
        left: safeAreaInsets.left / frame.width * physicalSize.width,
        bottom: safeAreaInsets.bottom / frame.height * physicalSize.height,
        right: safeAreaInsets.right / frame.width * physicalSize.width
    )

    // DisplayMetadataを作成
    let metadata = DisplayMetadata(
        fingerprint: fingerprintString,
        hardware: DisplayMetadata.HardwareInfo(
            displayID: displayID,
            vendorID: vendorID,
            modelID: modelID,
            serialNumber: serialNumber
        ),
        coordinates: DisplayMetadata.CoordinatesInfo(
            logical: DisplayMetadata.LogicalFrame(
                position: CGPoint(x: frame.minX, y: frame.minY),
                size: frame.size,
                visibleFrame: visibleFrame,
                safeAreaInsets: EdgeInsets(safeAreaInsets)
            ),
            physical: DisplayMetadata.PhysicalFrame(
                position: physicalPosition,
                size: physicalSize,
                visibleFrame: physicalVisibleFrame,
                safeAreaInsets: physicalSafeAreaInsets
            )
        ),
        display: DisplayMetadata.DisplayInfo(
            isMain: screen == NSScreen.main,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            name: screen.localizedName,
            resolution: DisplayMetadata.ResolutionInfo(
                points: screen.frame.size,
                pixels: CGSize(
                    width: screen.frame.size.width * screen.backingScaleFactor,
                    height: screen.frame.size.height * screen.backingScaleFactor
                ),
                backingScaleFactor: screen.backingScaleFactor,
                ppi: calculatedPPI
            ),
            refreshRate: refreshRate
        ),
        visual: DisplayMetadata.VisualInfo(
            colorSpaceName: deviceDescription[NSDeviceDescriptionKey("NSDeviceColorSpaceName")] as? String,
            colorSpaceLocalizedName: screen.colorSpace?.localizedName,
            bitsPerSample: deviceDescription[NSDeviceDescriptionKey("NSDeviceBitsPerSample")] as? Int,
            colorDepth: Int(screen.depth.rawValue),
            hdrMaxValue: screen.maximumExtendedDynamicRangeColorComponentValue,
            hdrMaxPotentialValue: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
            hdrMaxReferenceValue: screen.maximumReferenceExtendedDynamicRangeColorComponentValue
        ),
        capturedAt: Date()
    )

    print("--- Screen \(index) ---")

    // JSON出力
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if let jsonData = try? encoder.encode(metadata),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }

    print("")
}
