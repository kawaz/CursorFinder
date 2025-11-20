# LaserGuide v2 データモデル設計書

## 概要

LaserGuide v2では、データモデルを全面的に再設計し、シンプルで保守性の高い実装を目指します。

## 設計原則

1. **座標系の統一**: SpriteKit採用により左下原点・Y軸上向きに統一
2. **データの正規化**: 論理座標は実行時取得、物理座標のみ保存
3. **シンプルなエッジ管理**: PassSegmentのみ保存、Block は暗黙的
4. **柔軟な拡張性**: 将来の機能追加を見据えた設計

---

## 1. ディスプレイ識別

### DisplayFingerprint

ディスプレイを一意に識別するための情報。**解像度を含む**ことで、同じハードウェアでも解像度変更・回転時に別設定として扱う。

```swift
struct DisplayFingerprint: Codable, Hashable {
    let hardwareId: HardwareIdentifier
    let resolution: CGSize      // 論理解像度（points）
    let backingScaleFactor: CGFloat

    var stringRepresentation: String {
        let hw = "\(hardwareId.vendorID)-\(hardwareId.modelID)-\(hardwareId.serialNumber)"
        let res = "\(Int(resolution.width))x\(Int(resolution.height))"
        let scale = backingScaleFactor != 1.0 ? "@\(Int(backingScaleFactor))x" : ""
        return "\(hw)_\(res)\(scale)"
    }
}

struct HardwareIdentifier: Codable, Hashable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32
}
```

**重要**: メイン情報や論理座標上の位置は含めない（動的に変わるため）

---

## 2. 座標系

### 2種類のみ（SpriteKitと統一）

```swift
enum CoordinateSpace {
    case logical    // macOS論理座標（左下原点、Y上向き）
    case physical   // 物理座標mm（左下原点、Y上向き、正規化済み）
}
```

**利点**:
- SpriteKitも左下原点なのでY軸反転不要
- 座標変換がシンプル（スケールとオフセットのみ）

### 物理座標の正規化

保存時、全ディスプレイの物理座標を `(min(x), min(y))` を原点として正規化：

```swift
func normalize(layouts: [PhysicalLayout]) -> [PhysicalLayout] {
    let minX = layouts.map { $0.position.x }.min() ?? 0
    let minY = layouts.map { $0.position.y }.min() ?? 0

    return layouts.map { layout in
        var normalized = layout
        normalized.position.x -= minX
        normalized.position.y -= minY
        return normalized
    }
}
```

**利点**:
- メインディスプレイ変更の影響を受けない
- 常に左下が(0,0)で安定

---

## 3. ディスプレイモデル

### PhysicalLayout（保存用）

物理配置情報のみを保存。論理座標は含めない。

```swift
struct PhysicalLayout: Codable, Identifiable {
    let id: UUID
    let fingerprint: DisplayFingerprint

    // ユーザー設定の物理情報
    var position: Point2D  // mm（正規化済み）
    var size: Size2D       // mm

    // デバッグ用スナップショット（実行時は使用しない）
    var logicalSnapshot: LogicalSnapshot?
}

struct LogicalSnapshot: Codable {
    let frame: CGRect           // 保存時の論理座標
    let isMain: Bool
    let localizedName: String
    let capturedAt: Date
    let visibleFrame: CGRect
}
```

### Display（実行時）

実行時に論理情報と物理情報をマージ。

```swift
struct Display: Identifiable {
    let id: UUID
    let fingerprint: DisplayFingerprint

    // OSから取得（実行時のみ）
    let logicalFrame: CGRect
    let screen: NSScreen

    // 設定から読み込み
    var physicalPosition: Point2D
    var physicalSize: Size2D

    // 計算プロパティ
    var ppi: Double {
        let pixelWidth = logicalFrame.width * fingerprint.backingScaleFactor
        return pixelWidth / (physicalSize.width / 25.4)
    }
}
```

---

## 4. エッジナビゲーション

### 用語定義

- **Edge（辺）**: ディスプレイの一辺（top/bottom/left/right）
- **PassSegment**: 通過可能な区間（位置比率で補正）
- **Block**: PassSegmentがない範囲（暗黙的）

### データ構造

```swift
struct DisplayEdge: Identifiable, Codable {
    let id: UUID
    let displayId: UUID
    let side: EdgeSide

    // PassSegmentのみ保存、それ以外は自動的にBlock
    // ソート済み、交差禁止、0.0〜1.0を必ずしも埋めない
    var passSegments: [PassSegment]
}

struct PassSegment: Identifiable, Codable {
    let id: UUID
    let start: Double       // 0.0〜1.0
    let end: Double         // 0.0〜1.0, start <= end
    let pairedSegmentId: UUID
}

enum EdgeSide: String, Codable {
    case top, bottom, left, right
}
```

### 空セグメント（ワープポイント）

`start == end` の場合、ワープ先の点を表現：

```swift
// LGの右側のどこから越境しても、内蔵の右端(1.0)へワープ
PassSegment(id: "builtin2", start: 1.0, end: 1.0, pairedSegmentId: "lg2")
```

### 越境ロジック

```swift
func handleCrossing(at position: Double, edge: DisplayEdge) -> Double? {
    // 1. PassSegmentを探す
    guard let segment = edge.passSegments.first(where: {
        $0.start <= position && position < $0.end
    }) else {
        return nil  // Block
    }

    // 2. ペアのSegmentを取得
    guard let paired = findSegment(id: segment.pairedSegmentId) else {
        return nil
    }

    // 3. 位置を計算
    if paired.start == paired.end {
        // 空セグメント → 常に同じ位置
        return paired.start
    } else {
        // 通常セグメント → 位置比率で補正
        let ratio = (position - segment.start) / (segment.end - segment.start)
        return paired.start + ratio * (paired.end - paired.start)
    }
}
```

---

## 5. ワークスペース設定

```swift
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String  // DisplayFingerprintの組み合わせから生成

    // 保存する物理情報
    let physicalLayouts: [PhysicalLayout]
    let edges: [DisplayEdge]

    let metadata: Metadata

    struct Metadata: Codable {
        let created: Date
        let modified: Date
    }
}

func generateConfigurationKey(fingerprints: [DisplayFingerprint]) -> String {
    let sorted = fingerprints
        .map { $0.stringRepresentation }
        .sorted()
        .joined(separator: "+")
    return "config_\(sorted)"
}
```

---

## 6. 追加機能

### 修飾キーによる強制Block

```swift
struct ModifierKeySet: Codable, Hashable {
    var shift: Bool = false
    var control: Bool = false
    var option: Bool = false
    var command: Bool = false

    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        return shift == flags.contains(.shift) &&
               control == flags.contains(.control) &&
               option == flags.contains(.option) &&
               command == flags.contains(.command)
    }

    var displayString: String {
        var keys: [String] = []
        if control { keys.append("⌃") }
        if option { keys.append("⌥") }
        if shift { keys.append("⇧") }
        if command { keys.append("⌘") }
        return keys.isEmpty ? "なし" : keys.joined()
    }
}

struct AppSettings: Codable {
    var forceBlockModifiers: ModifierKeySet = .option
    var forceBlockEnabled: Bool = true
}
```

---

## 設定例

### デフォルト（OS標準配置）

```swift
// 論理的に隣接している範囲のみPass
LG.passSegments = [
    bottom: [
        PassSegment(start: 0.0, end: 1.0, pairedSegmentId: "builtin1")
    ]
]

builtin.passSegments = [
    top: [
        PassSegment(start: 0.0, end: 0.996, pairedSegmentId: "lg1")
        // 0.996〜1.0 は Pass Segmentなし → Block
    ]
]
```

### 物理的に自然な配置

```swift
// 物理幅に合わせて分割、右端へのワープを設定
LG.passSegments = [
    bottom: [
        PassSegment(start: 0.0, end: 0.327, pairedSegmentId: "builtin1"),
        PassSegment(start: 0.327, end: 1.0, pairedSegmentId: "builtin2")
    ]
]

builtin.passSegments = [
    top: [
        PassSegment(start: 0.0, end: 0.996, pairedSegmentId: "lg1"),
        PassSegment(start: 1.0, end: 1.0, pairedSegmentId: "lg2")  // 空セグメント
    ]
]
```

---

## まとめ

この設計により：

1. **シンプル**: PassSegmentのみ管理、Blockは暗黙的
2. **柔軟**: 任意のEdge同士をペアリング可能
3. **安定**: メインディスプレイ変更の影響なし
4. **拡張性**: 空セグメントで複雑な動作も表現可能
