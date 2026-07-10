// 既存コア型 (Points/Side/DisplayPose/PassSegment/Display) への Codable 適合 (DR-0007 決定 6)
//
// 「永続スキーマと WebView render model はどちらも同じ Swift 型定義から encode する」という
// 決定 6 の正本一元化を、Persistence 配下のみ書き込み許可という委譲スコープ内で満たすため、
// 既存ファイル (Points.swift 等) を変更せず extension で Codable 適合を後付けする。
//
// Swift の Codable 自動合成は「型の primary 宣言と同じファイル内」でしか働かない制約があり
// (extension からの適合宣言では `error: extension outside of file declaring struct ...
// prevents automatic synthesis` になる)、ここでは全型について手動で init(from:)/encode(to:) を
// 書く。DisplayPose のみ、custom init に `scaleX > 0 && scaleY > 0` の precondition があるため
// デコード後にそのまま格納せず、不正値は precondition crash ではなく DecodingError として
// 呼び出し側に委ねる (壊れた/改ざんされた永続データを読んだ瞬間にクラッシュしないようにする)。
import Foundation

extension PhysicalPoint: Codable {
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
    }
}

extension LogicalRect: Codable {
    private enum CodingKeys: String, CodingKey { case minX, minY, maxX, maxY }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minX: try c.decode(Double.self, forKey: .minX), minY: try c.decode(Double.self, forKey: .minY),
            maxX: try c.decode(Double.self, forKey: .maxX), maxY: try c.decode(Double.self, forKey: .maxY))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minX, forKey: .minX)
        try c.encode(minY, forKey: .minY)
        try c.encode(maxX, forKey: .maxX)
        try c.encode(maxY, forKey: .maxY)
    }
}

// Side: String rawValue の enum は標準ライブラリの合成対象だが、これも primary 宣言ファイル外の
// 適合では自動合成されないため明示的に RawRepresentable 経由で実装する。
extension Side: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Side(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "Unknown Side rawValue: \(raw)")
        }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension PassSegment: Codable {
    private enum CodingKeys: String, CodingKey { case id, displayId, side, logicalStart, logicalEnd, pairedSegmentId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            displayId: try c.decode(String.self, forKey: .displayId),
            side: try c.decode(Side.self, forKey: .side),
            logicalStart: try c.decode(Double.self, forKey: .logicalStart),
            logicalEnd: try c.decode(Double.self, forKey: .logicalEnd),
            pairedSegmentId: try c.decode(String.self, forKey: .pairedSegmentId))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayId, forKey: .displayId)
        try c.encode(side, forKey: .side)
        try c.encode(logicalStart, forKey: .logicalStart)
        try c.encode(logicalEnd, forKey: .logicalEnd)
        try c.encode(pairedSegmentId, forKey: .pairedSegmentId)
    }
}

extension Display: Codable {
    private enum CodingKeys: String, CodingKey { case id, logicalBounds, pose }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            logicalBounds: try c.decode(LogicalRect.self, forKey: .logicalBounds),
            pose: try c.decode(DisplayPose.self, forKey: .pose))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(logicalBounds, forKey: .logicalBounds)
        try c.encode(pose, forKey: .pose)
    }
}

extension DisplayPose: Codable {
    private enum CodingKeys: String, CodingKey {
        case translate, scaleX, scaleY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let translate = try container.decode(PhysicalPoint.self, forKey: .translate)
        let scaleX = try container.decode(Double.self, forKey: .scaleX)
        let scaleY = try container.decode(Double.self, forKey: .scaleY)
        guard scaleX > 0, scaleY > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scaleX, in: container,
                debugDescription: "DisplayPose.scaleX/scaleY must be > 0 (got \(scaleX), \(scaleY))")
        }
        self.init(translate: translate, scaleX: scaleX, scaleY: scaleY)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translate, forKey: .translate)
        try container.encode(scaleX, forKey: .scaleX)
        try container.encode(scaleY, forKey: .scaleY)
    }
}
