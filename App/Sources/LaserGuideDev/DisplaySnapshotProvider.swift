// DisplaySnapshotProvider (DR-0005: CG y-down 正、NSScreen 系を判定経路へ持ち込まない)
//
// CGGetActiveDisplayList → 各 CGDirectDisplayID から:
//   - hardwareId 相当の永続 id: `vendor-model-serial-unit` (DR-0007)
//   - logicalBounds: CGDisplayBounds (CG y-down, px)
//   - 初期 pose: translate=0, scale=(mm/px). mm 不取得時は fallback 110dpi。
//
// 「translate=0, scale=(mm/px)」の設計判断: DR-0005 「初期 pose は論理隣接をそのまま mm へ」
// を、`DisplayPose.toPhysical(p) = translate + p*scale` の形に落とすと translate=0 が導かれる。
// (bounds.minX 位置での物理値 = bounds.minX*scale となり、per-display の px→mm 変換のみで、
// cross-display の物理継ぎ目連続はキャリブレーション UI で別途整合させる — Phase 1 は各モニタ
// 独立の mm 空間として振る舞う。DR-0005 の主要件「physical straightness 保証」を per-display
// では満たしつつ、cross-display continuity は explicit calibration に委ねる)。
import CoreGraphics
import Foundation
import LaserGuideCore

/// mm/px スケール導出のフォールバック DPI (DR-0005: CGDisplayScreenSize が 0/不正値の時)。
public let fallbackDPI: Double = 110.0

/// mm/px = 25.4 / dpi
public let mmPerInch: Double = 25.4

public struct DisplayScanResult: Equatable, Sendable {
    public var snapshots: [DisplaySnapshot]
    public var initialPoses: [String: DisplayPose]
    /// mm 実測が取れず fallback DPI を使ったモニタ id 群 (UI で「未取得・要手動補正」表示のため)。
    public var displaysUsingFallbackDPI: Set<String>
    /// CGDirectDisplayID との対応 (NSScreen 突合 / overlay 配置に使う)。
    public var cgDisplayIdOf: [String: CGDirectDisplayID]
}

public enum DisplaySnapshotProvider {

    /// 現在アクティブな CG ディスプレイを走査し、Snapshot + 初期 pose を返す。
    public static func scan() -> DisplayScanResult {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else {
            return DisplayScanResult(snapshots: [], initialPoses: [:],
                                     displaysUsingFallbackDPI: [], cgDisplayIdOf: [:])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var snapshots: [DisplaySnapshot] = []
        var poses: [String: DisplayPose] = [:]
        var fallback: Set<String> = []
        var cgOf: [String: CGDirectDisplayID] = [:]

        for cgId in ids.prefix(Int(count)) {
            let bounds = CGDisplayBounds(cgId)
            let logicalBounds = LogicalRect(
                minX: Double(bounds.minX), minY: Double(bounds.minY),
                maxX: Double(bounds.maxX), maxY: Double(bounds.maxY)
            )
            let hwId = hardwareId(cgId)
            snapshots.append(DisplaySnapshot(id: hwId, logicalBounds: logicalBounds))

            let (scaleX, scaleY, usedFallback) = scaleFor(cgId: cgId, bounds: bounds)
            poses[hwId] = DisplayPose(
                translate: PhysicalPoint(x: 0, y: 0),
                scaleX: scaleX,
                scaleY: scaleY
            )
            if usedFallback { fallback.insert(hwId) }
            cgOf[hwId] = cgId
        }

        return DisplayScanResult(
            snapshots: snapshots, initialPoses: poses,
            displaysUsingFallbackDPI: fallback, cgDisplayIdOf: cgOf
        )
    }

    // swiftlint:disable large_tuple
    /// mm 実測 (CGDisplayScreenSize) と px サイズから mm/px スケールを導出する。
    /// mm=0 のディスプレイ (プロジェクタ・EDID 不備) は fallback DPI を使い、`usedFallback=true` を返す。
    ///
    /// 3-要素 tuple は SwiftLint の large_tuple 対象になるが、この 3 値 (X 軸スケール / Y 軸スケール
    /// / fallback フラグ) は「1 回の scale 導出結果」として密結合で、struct 化するほど公開語彙にする
    /// 意味は薄い (呼び出し側 1 箇所)。
    static func scaleFor(cgId: CGDirectDisplayID, bounds: CGRect) -> (scaleX: Double, scaleY: Double, usedFallback: Bool) {
    // swiftlint:enable large_tuple
        let mm = CGDisplayScreenSize(cgId)
        let pxW = Double(bounds.width)
        let pxH = Double(bounds.height)
        guard pxW > 0, pxH > 0 else {
            let s = mmPerInch / fallbackDPI
            return (s, s, true)
        }
        if mm.width > 0.5 && mm.height > 0.5 {
            return (mm.width / pxW, mm.height / pxH, false)
        }
        // mm 不取得: fallback DPI から mm/px を算出 (両軸同値の square pixel 仮定)。
        let s = mmPerInch / fallbackDPI
        return (s, s, true)
    }

    /// hardwareId (DR-0007): vendor-model-serial-unit を "-" で連結。0 の欄も含めてキー化 (機種再現性優先)。
    static func hardwareId(_ cgId: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(cgId)
        let model = CGDisplayModelNumber(cgId)
        let serial = CGDisplaySerialNumber(cgId)
        let unit = CGDisplayUnitNumber(cgId)
        return "\(vendor)-\(model)-\(serial)-\(unit)"
    }
}
