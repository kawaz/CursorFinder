// Display.swift
import Cocoa

/// ディスプレイ情報（階層化構造）
struct Display: Identifiable, Codable {
    let id: UUID
    var hardware: HardwareInfo
    var coordinates: CoordinatesInfo
    var display: DisplayInfo
    var visual: VisualInfo

    // OS標準のPassSegment（論理的隣接範囲、PP/PB/BP/BB判定に使用）
    var osPassSegments: [PassSegment]

    // ユーザー設定のPassSegment（実際の越境に使用）
    var passSegments: [PassSegment]

    // MARK: - Nested Types

    /// ハードウェア情報
    struct HardwareInfo: Codable {
        let fingerprint: String  // "000006100000A051FD626D62-3456x2234x1"
        let displayID: UInt32
        let vendorID: UInt32
        let vendorIDHex: String
        let modelID: UInt32
        let modelIDHex: String
        let serialNumber: UInt32
        let serialNumberHex: String
    }

    /// Codable版インセット（NSEdgeInsetsのシリアライズ可能版）
    struct CoordinateInsets: Codable {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat

        init(_ nsInsets: NSEdgeInsets) {
            self.top = nsInsets.top
            self.left = nsInsets.left
            self.bottom = nsInsets.bottom
            self.right = nsInsets.right
        }

        init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        static var zero: CoordinateInsets {
            CoordinateInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    /// 座標フレーム
    struct CoordinateFrame: Codable {
        var position: CGPoint
        var size: CGSize
        var visibleFrame: CGRect
        var safeAreaInsets: CoordinateInsets
    }

    /// 座標情報（論理+物理）
    struct CoordinatesInfo: Codable {
        var logical: CoordinateFrame
        var physical: CoordinateFrame
    }

    /// ディスプレイ情報
    struct DisplayInfo: Codable {
        let isMain: Bool
        let isBuiltIn: Bool
        let name: String
        let resolution: ResolutionInfo
        let refreshRate: Double
    }

    /// 解像度情報
    struct ResolutionInfo: Codable {
        let points: CGSize
        let pixels: CGSize
        let backingScaleFactor: CGFloat
        let ppi: Double
    }

    /// ビジュアル情報
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

// MARK: - Display Creation

extension Display {
    /// NSScreenからDisplayを作成（デフォルト物理配置）
    static func create(from screen: NSScreen, physicalPosition: Point2D = .zero) -> Display {
        let deviceDescription = screen.deviceDescription
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

        // ハードウェア情報
        let vendorID = CGDisplayVendorNumber(displayID)
        let modelID = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        let fingerprint = DisplayFingerprint(screen: screen)

        let hardware = HardwareInfo(
            fingerprint: fingerprint.stringRepresentation,
            displayID: displayID,
            vendorID: vendorID,
            vendorIDHex: String(format: "%08X", vendorID),
            modelID: modelID,
            modelIDHex: String(format: "%08X", modelID),
            serialNumber: serialNumber,
            serialNumberHex: String(format: "%08X", serialNumber)
        )

        // 物理サイズとPPI
        let physicalSizeCG = CGDisplayScreenSize(displayID)
        let pixelWidth = screen.frame.size.width * screen.backingScaleFactor
        let calculatedPPI = physicalSizeCG.width > 0 ? pixelWidth / (physicalSizeCG.width / 25.4) : 0

        // リフレッシュレート
        let refreshRate: Double
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            refreshRate = mode.refreshRate
        } else {
            refreshRate = 0
        }

        // 物理座標のvisibleFrameとsafeAreaInsetsを補完
        let logicalFrame = screen.frame
        let logicalVisibleFrame = screen.visibleFrame
        let logicalSafeAreaInsets = screen.safeAreaInsets

        let physicalSize = Size2D(physicalSizeCG)

        let physicalVisibleFrame = CGRect(
            x: physicalPosition.x + (logicalVisibleFrame.minX - logicalFrame.minX) / logicalFrame.width * physicalSize.width,
            y: physicalPosition.y + (logicalVisibleFrame.minY - logicalFrame.minY) / logicalFrame.height * physicalSize.height,
            width: logicalVisibleFrame.width / logicalFrame.width * physicalSize.width,
            height: logicalVisibleFrame.height / logicalFrame.height * physicalSize.height
        )

        let physicalSafeAreaInsets = CoordinateInsets(
            top: logicalSafeAreaInsets.top / logicalFrame.height * physicalSize.height,
            left: logicalSafeAreaInsets.left / logicalFrame.width * physicalSize.width,
            bottom: logicalSafeAreaInsets.bottom / logicalFrame.height * physicalSize.height,
            right: logicalSafeAreaInsets.right / logicalFrame.width * physicalSize.width
        )

        // 座標情報
        let coordinates = CoordinatesInfo(
            logical: CoordinateFrame(
                position: CGPoint(x: logicalFrame.minX, y: logicalFrame.minY),
                size: logicalFrame.size,
                visibleFrame: logicalVisibleFrame,
                safeAreaInsets: CoordinateInsets(logicalSafeAreaInsets)
            ),
            physical: CoordinateFrame(
                position: physicalPosition.cgPoint,
                size: physicalSize.cgSize,
                visibleFrame: physicalVisibleFrame,
                safeAreaInsets: physicalSafeAreaInsets
            )
        )

        // ディスプレイ情報
        let displayInfo = DisplayInfo(
            isMain: screen == NSScreen.main,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            name: screen.localizedName,
            resolution: ResolutionInfo(
                points: screen.frame.size,
                pixels: CGSize(
                    width: screen.frame.size.width * screen.backingScaleFactor,
                    height: screen.frame.size.height * screen.backingScaleFactor
                ),
                backingScaleFactor: screen.backingScaleFactor,
                ppi: calculatedPPI
            ),
            refreshRate: refreshRate
        )

        // ビジュアル情報
        let visual = VisualInfo(
            colorSpaceName: deviceDescription[NSDeviceDescriptionKey("NSDeviceColorSpaceName")] as? String,
            colorSpaceLocalizedName: screen.colorSpace?.localizedName,
            bitsPerSample: deviceDescription[NSDeviceDescriptionKey("NSDeviceBitsPerSample")] as? Int,
            colorDepth: Int(screen.depth.rawValue),
            hdrMaxValue: screen.maximumExtendedDynamicRangeColorComponentValue,
            hdrMaxPotentialValue: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
            hdrMaxReferenceValue: screen.maximumReferenceExtendedDynamicRangeColorComponentValue
        )

        return Display(
            id: UUID(),
            hardware: hardware,
            coordinates: coordinates,
            display: displayInfo,
            visual: visual,
            osPassSegments: [],  // 後で生成
            passSegments: []     // 後で生成
        )
    }
}
