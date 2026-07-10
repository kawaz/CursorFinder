// v1 (配布中 v0.12.1) の実スキーマを写し取った読み取り専用 DTO (DR-0007 決定 3)。
//
// 正本は LaserGuide.v1.backup/Models/DisplayIdentifier.swift (読み取り専用参照)。
// フィールド名・型・JSON 構造は下記引用元と 1:1 で対応させ、実データが decode できることを
// 最優先する (v1 を書き換える対象ではないので、v1 側の命名や設計判断への言及・改善は行わない)。
//
//   DisplayIdentifier   : Models/DisplayIdentifier.swift:5-20   (vendorID/modelID/serialNumber)
//   PhysicalDisplayLayout: Models/DisplayIdentifier.swift:23-37 (identifier/position/size, mm)
//   EdgeDirection       : Models/DisplayIdentifier.swift:40-45  (top/bottom/left/right)
//   EdgeZone            : Models/DisplayIdentifier.swift:48-62  (0-1 正規化区間 + UUID id)
//   EdgeZonePair        : Models/DisplayIdentifier.swift:65-75  (sourceZoneId/targetZoneId で対応)
//   DisplayConfiguration: Models/DisplayIdentifier.swift:78-100 (displays/timestamp/edgeZones/edgeZonePairs)
import Foundation

/// v1 DisplayIdentifier の写し。stringRepresentation が v3 の hardwareId と同じ文字列になる
/// (DR-0007 決定 1: hardwareId のみで同一性判定)。
struct V1DisplayIdentifier: Codable, Equatable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32

    var stringRepresentation: String { "\(vendorID)-\(modelID)-\(serialNumber)" }
}

struct V1PhysicalPoint: Codable, Equatable {
    let x: Double  // mm
    let y: Double  // mm
}

struct V1PhysicalSize: Codable, Equatable {
    let width: Double   // mm
    let height: Double  // mm
}

/// v1 PhysicalDisplayLayout の写し。position は「Bottom-left corner in mm」
/// (v1 コメント原文、Models/DisplayIdentifier.swift:25)。
struct V1PhysicalDisplayLayout: Codable, Equatable {
    let identifier: V1DisplayIdentifier
    let position: V1PhysicalPoint
    let size: V1PhysicalSize
}

enum V1EdgeDirection: String, Codable, Equatable, CaseIterable {
    case top, bottom, left, right
}

/// v1 EdgeZone の写し。rangeStart/rangeEnd は 0.0-1.0 の正規化区間 (px 情報を持たない)。
struct V1EdgeZone: Codable, Equatable {
    let id: UUID
    let displayId: String  // V1DisplayIdentifier.stringRepresentation
    let edge: V1EdgeDirection
    var rangeStart: Double
    var rangeEnd: Double
}

struct V1EdgeZonePair: Codable, Equatable {
    let id: UUID
    let sourceZoneId: UUID
    let targetZoneId: UUID
}

/// v1 DisplayConfiguration の写し。JSONEncoder/JSONDecoder のデフォルト設定
/// (date strategy 未指定 = .deferredToDate) のまま v1 が書き出しているため
/// (CalibrationDataManager.swift:43 `JSONEncoder().encode(configuration)`)、
/// このデコード側も戦略を明示せずデフォルトのまま使う。
struct V1DisplayConfiguration: Codable, Equatable {
    let displays: [V1PhysicalDisplayLayout]
    let timestamp: Date
    var edgeZones: [V1EdgeZone]
    var edgeZonePairs: [V1EdgeZonePair]
}
