// Display.swift
import Cocoa

/// 論理座標スナップショット（デバッグ用、実行時は使用しない）
struct LogicalSnapshot: Codable {
    let frame: CGRect
    let isMain: Bool
    let localizedName: String
    let capturedAt: Date
    let visibleFrame: CGRect
}

/// 物理レイアウト（保存用）
struct PhysicalLayout: Codable, Identifiable {
    let id: UUID
    let fingerprint: DisplayFingerprint

    // ユーザー設定の物理情報
    var position: Point2D  // mm（正規化済み）
    var size: Size2D       // mm

    // デバッグ用スナップショット（実行時は使用しない）
    var logicalSnapshot: LogicalSnapshot?

    init(
        id: UUID = UUID(),
        fingerprint: DisplayFingerprint,
        position: Point2D,
        size: Size2D,
        logicalSnapshot: LogicalSnapshot? = nil
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.position = position
        self.size = size
        self.logicalSnapshot = logicalSnapshot
    }
}

/// 実行時のディスプレイ情報（論理+物理の統合）
struct Display: Identifiable {
    let id: UUID
    let fingerprint: DisplayFingerprint

    // OSから取得（実行時のみ）
    let logicalFrame: CGRect
    let screen: NSScreen

    // 設定から読み込み
    var physicalPosition: Point2D
    var physicalSize: Size2D

    init(
        id: UUID = UUID(),
        fingerprint: DisplayFingerprint,
        logicalFrame: CGRect,
        screen: NSScreen,
        physicalPosition: Point2D,
        physicalSize: Size2D
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.logicalFrame = logicalFrame
        self.screen = screen
        self.physicalPosition = physicalPosition
        self.physicalSize = physicalSize
    }

    /// PPI（Pixels Per Inch）
    var ppi: Double {
        let pixelWidth = logicalFrame.width * fingerprint.backingScaleFactor
        let physicalWidthInches = physicalSize.width / 25.4
        guard physicalWidthInches > 0 else { return 0 }
        return pixelWidth / physicalWidthInches
    }

    /// 内蔵ディスプレイかどうか
    var isBuiltIn: Bool {
        let deviceDescription = screen.deviceDescription
        guard let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    /// メインディスプレイかどうか
    var isMain: Bool {
        screen == NSScreen.main
    }

    /// ディスプレイ名
    var name: String {
        let localizedName = screen.localizedName
        if !localizedName.isEmpty {
            return localizedName
        }
        return isBuiltIn ? "内蔵ディスプレイ" : "外部ディスプレイ"
    }

    /// displayIDを取得
    var displayID: CGDirectDisplayID? {
        let deviceDescription = screen.deviceDescription
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension Display {
    /// NSScreenとPhysicalLayoutから作成
    static func merge(screen: NSScreen, layout: PhysicalLayout) -> Display {
        Display(
            id: layout.id,
            fingerprint: layout.fingerprint,
            logicalFrame: screen.frame,
            screen: screen,
            physicalPosition: layout.position,
            physicalSize: layout.size
        )
    }

    /// NSScreenからデフォルト作成（物理サイズはOSから取得）
    static func createDefault(screen: NSScreen, position: Point2D = .zero) -> Display {
        let fingerprint = DisplayFingerprint(screen: screen)

        // 物理サイズをOSから取得
        let deviceDescription = screen.deviceDescription
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let physicalSizeCG = CGDisplayScreenSize(displayID)
        let physicalSize = Size2D(physicalSizeCG)

        return Display(
            fingerprint: fingerprint,
            logicalFrame: screen.frame,
            screen: screen,
            physicalPosition: position,
            physicalSize: physicalSize
        )
    }
}

/// 物理レイアウトの正規化
extension Array where Element == PhysicalLayout {
    /// 全体の最小点を原点として正規化
    func normalized() -> [PhysicalLayout] {
        guard !isEmpty else { return [] }

        let minX = self.map { $0.position.x }.min() ?? 0
        let minY = self.map { $0.position.y }.min() ?? 0

        return self.map { layout in
            var normalized = layout
            normalized.position.x -= minX
            normalized.position.y -= minY
            return normalized
        }
    }
}
