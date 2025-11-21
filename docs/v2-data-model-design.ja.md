# LaserGuide v2 データモデル設計書

## 概要

LaserGuide v2では、データモデルを全面的に再設計し、シンプルで保守性の高い実装を目指します。

## 設計原則

1. **座標系の統一**: SpriteKit採用により左下原点・Y軸上向きに統一
2. **データの正規化**: 論理座標は実行時取得、物理座標のみ保存
3. **階層化構造**: logical/physical完全対称で比較しやすい
4. **シンプルなエッジ管理**: PassSegmentのみ保存、Block は暗黙的
5. **柔軟な拡張性**: 将来の機能追加を見据えた設計

---

## 1. ディスプレイ識別

### DisplayFingerprint

ディスプレイを一意に識別するための情報。**解像度を含む**ことで、同じハードウェアでも解像度変更・回転時に別設定として扱う。

```swift
struct DisplayFingerprint: Codable, Hashable {
    let hardwareId: HardwareIdentifier
    let resolution: CGSize      // 論理解像度（points）
    let backingScaleFactor: CGFloat  // Retina倍率（1.0, 1.5, 2.0など）

    var stringRepresentation: String {
        // ハードウェアID（24文字固定、16進数、ハイフンなし）
        let hw = String(format: "%08X%08X%08X",
                       hardwareId.vendorID,
                       hardwareId.modelID,
                       hardwareId.serialNumber)

        // 解像度
        let res = "\(Int(resolution.width))x\(Int(resolution.height))"

        // スケール（x統一形式、浮動小数点対応）
        let scale: String
        if backingScaleFactor == 1.0 {
            scale = "x1"
        } else if backingScaleFactor.truncatingRemainder(dividingBy: 1) == 0 {
            scale = "x\(Int(backingScaleFactor))"
        } else {
            scale = "x\(backingScaleFactor)"
        }

        return "\(hw)-\(res)\(scale)"
    }
}

struct HardwareIdentifier: Codable, Hashable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32
}
```

**例**:
```
標準:    000006100000A051FD626D62-3456x2234x1
Retina:  000006100000A051FD626D62-1728x1117x2
特殊:    000006100000A051FD626D62-2304x1489x1.5
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
func normalize(displays: [Display]) -> [Display] {
    let minX = displays.map { $0.coordinates.physical.position.x }.min() ?? 0
    let minY = displays.map { $0.coordinates.physical.position.y }.min() ?? 0

    return displays.map { display in
        var normalized = display
        normalized.coordinates.physical.position.x -= minX
        normalized.coordinates.physical.position.y -= minY
        return normalized
    }
}
```

**利点**:
- メインディスプレイ変更の影響を受けない
- 常に左下が(0,0)で安定

---

## 3. ディスプレイモデル

### Display（統一モデル）

実行時とデバッグ出力の両方で使用する階層化構造。

```swift
struct Display: Identifiable, Codable {
    let id: UUID
    let hardware: HardwareInfo
    let coordinates: CoordinatesInfo
    let display: DisplayInfo
    let visual: VisualInfo

    struct HardwareInfo: Codable {
        let fingerprint: String  // "000006100000A051FD626D62-3456x2234x1"
        let displayID: UInt32
        let vendorID: UInt32
        let vendorIDHex: String  // "00000610"（参照用）
        let modelID: UInt32
        let modelIDHex: String   // "0000A051"（参照用）
        let serialNumber: UInt32
        let serialNumberHex: String  // "FD626D62"（参照用）
    }

    // Codable版インセット（NSEdgeInsetsのシリアライズ可能版）
    struct CoordinateInsets: Codable {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
    }

    struct CoordinateFrame: Codable {
        let position: CGPoint
        let size: CGSize
        let visibleFrame: CGRect
        let safeAreaInsets: CoordinateInsets
    }

    struct CoordinatesInfo: Codable {
        let logical: CoordinateFrame
        let physical: CoordinateFrame
    }

    struct DisplayInfo: Codable {
        let isMain: Bool
        let isBuiltIn: Bool
        let name: String
        let resolution: ResolutionInfo
        let refreshRate: Double  // Hz
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
```

### JSON出力例

```json
{
  "id": "builtin-uuid",
  "hardware": {
    "fingerprint": "000006100000A051FD626D62-3456x2234x1",
    "displayID": 1,
    "vendorID": 1552,
    "vendorIDHex": "00000610",
    "modelID": 41041,
    "modelIDHex": "0000A051",
    "serialNumber": 4251086178,
    "serialNumberHex": "FD626D62"
  },
  "coordinates": {
    "logical": {
      "position": [0, 0],
      "size": [3456, 2234],
      "visibleFrame": [[0, 0], [3456, 2164]],
      "safeAreaInsets": {"top": 64, "left": 0, "bottom": 0, "right": 0}
    },
    "physical": {
      "position": [0, 0],
      "size": [344.2, 222.5],
      "visibleFrame": [[0, 0], [344.2, 215.5]],
      "safeAreaInsets": {"top": 6.37, "left": 0, "bottom": 0, "right": 0}
    }
  },
  "display": {
    "isMain": true,
    "isBuiltIn": true,
    "name": "Built-in Display",
    "resolution": {
      "points": [3456, 2234],
      "pixels": [3456, 2234],
      "backingScaleFactor": 1,
      "ppi": 255.0
    },
    "refreshRate": 120
  },
  "visual": {
    "colorSpaceName": "NSCalibratedRGBColorSpace",
    "colorSpaceLocalizedName": "Color LCD",
    "bitsPerSample": 8,
    "colorDepth": 520,
    "hdrMaxValue": 1,
    "hdrMaxPotentialValue": 16,
    "hdrMaxReferenceValue": 0
  }
}
```

---

## 4. エッジナビゲーション

### 用語定義

- **Edge（辺）**: ディスプレイの一辺（top/bottom/left/right）
- **PassSegment**: 通過可能な区間
- **Block**: PassSegmentがない範囲（暗黙的）

### データ構造

```swift
struct PassSegment: Identifiable, Codable {
    let id: UUID
    let displayId: UUID  // このSegmentが属するDisplay（検索用）
    let side: EdgeSide

    // 論理座標での範囲（px単位、実座標値）
    let logical: SegmentRange

    // 物理座標での範囲（mm単位、実座標値）
    let physical: SegmentRange

    // ペアリング（アプリロジックで使用）
    let pairedSegmentId: UUID

    // デバッグ用ヒント（JSONの可読性向上、アプリロジックでは使用しない）
    let pairedDisplayId: UUID?
    let pairedDisplayName: String?
    let pairedSide: EdgeSide?
}

struct SegmentRange: Codable {
    let start: Double  // 実座標値（正規化しない）
    let end: Double    // start <= end（空セグメント許可）

    var isEmpty: Bool {
        start == end
    }

    func contains(_ value: Double) -> Bool {
        guard !isEmpty else { return false }
        return start <= value && value <= end  // 閉区間
    }
}

enum EdgeSide: String, Codable {
    case top, bottom, left, right
}
```

### PassSegmentの例

```swift
// 内蔵 top（全域Pass）
PassSegment(
    id: UUID("..."),
    displayId: UUID("builtin-uuid"),
    side: .top,
    logical: SegmentRange(start: 0.0, end: 3440.0),      // 0〜3440px
    physical: SegmentRange(start: 0.0, end: 342.6),      // 0〜342.6mm
    pairedSegmentId: UUID("..."),
    pairedDisplayId: UUID("lg-uuid"),
    pairedDisplayName: "LG ULTRAGEAR+",
    pairedSide: .bottom
)

// 空セグメント（ワープポイント）
PassSegment(
    id: UUID("..."),
    displayId: UUID("builtin-uuid"),
    side: .top,
    logical: SegmentRange(start: 3456.0, end: 3456.0),   // 点
    physical: SegmentRange(start: 344.2, end: 344.2),    // 点
    pairedSegmentId: UUID("..."),
    pairedDisplayId: UUID("lg-uuid"),
    pairedDisplayName: "LG ULTRAGEAR+",
    pairedSide: .bottom
)
```

### 越境ロジック（高速）

```swift
func handleCrossing(mouseX: Double, edge: DisplayEdge) -> Double? {
    // 1. 直接比較（正規化不要）
    guard let segment = edge.passSegments.first(where: {
        $0.logical.contains(mouseX)  // 実座標値で直接比較
    }) else {
        return nil  // Block
    }

    // 2. ペア取得
    guard let paired = findSegment(id: segment.pairedSegmentId) else {
        return nil
    }

    // 3. 位置を計算
    if paired.logical.isEmpty {
        // 空セグメント → ワープ
        return paired.logical.start
    } else {
        // 通常セグメント → 位置比率で補正
        let ratio = (mouseX - segment.logical.start) /
                    (segment.logical.end - segment.logical.start)
        return paired.logical.start +
               ratio * (paired.logical.end - paired.logical.start)
    }
}
```

**利点**:
- 正規化計算不要（高速）
- JSONで実座標値が見える（デバッグしやすい）
- 物理補正も簡単（`physical.start/end`を使う）

---

## 5. ワークスペース設定

```swift
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String
    let displays: [Display]
    let metadata: ConfigMetadata

    struct ConfigMetadata: Codable {
        let created: Date
        var modified: Date

        // アプリバージョン（Info.plistから）
        let appVersion: String           // "1.2.3"（SemVer）
        let appBuildNumber: String       // "42" or "1.2.3.42"

        // Git情報（ビルド時にInfo.plistに埋め込む、オプショナル）
        let gitCommit: String?           // "5e06c9a" or "5e06c9a-dirty"
        let gitCommitFull: String?       // "5e06c9a3ad8c0bda92c49de21ab1c0031b33a167"
        let gitBranch: String?           // "v2", "main"
        let gitTag: String?              // "v1.2.3"（タグビルド時のみ）
        let gitDescribe: String?         // "v0.12.1-1-g5e06c9a"
        let buildDate: String?           // "2025-11-21T01:57:15Z"
    }
}

func generateConfigurationKey(fingerprints: [String]) -> String {
    let sorted = fingerprints.sorted().joined(separator: "_")
    return "config_\(sorted)"
}
```

**注**: PassSegmentは各Display内に保存。EdgeNavigationMapは実行時に全PassSegmentをインデックス化して高速検索用に使用。

**設定キー例**:
```
config_000006100000A051FD626D62-3456x2234x1_00001E6D00009E8B0007543B-3440x1440x1
       ^^^^^^^^^^^^^^^^^^^^^^^^-^^^^^^^^^^^_^^^^^^^^^^^^^^^^^^^^^^^^-^^^^^^^^^^^
       Display 1 fingerprint                Display 2 fingerprint
```

**特徴**:
- URL安全（`+`記号なし）
- ファイル名安全（エスケープ不要）
- アンダーバーで分割可能
- 固定長24文字のハードウェアID

---

## 6. システムメタデータ

### SystemMetadata（デバッグ用、設定ファイルには保存しない）

```swift
struct SystemMetadata: Codable {
    // OS情報
    let osVersion: String           // "15.6.0"
    let osBuildNumber: String?      // "24A352"

    // ハードウェア情報
    let hardwareModel: String       // "MacBookPro18,2"
    let cpuBrand: String            // "Apple M1 Max"
    let cpuPhysicalCores: Int       // 10
    let cpuLogicalCores: Int        // 10
    let memoryGB: Int               // 64

    // GPU情報（複数GPU対応）
    let gpus: [GPUInfo]

    let capturedAt: Date
}

struct GPUInfo: Codable {
    let name: String                // "Apple M1 Max"
    let isLowPower: Bool
    let isRemovable: Bool           // eGPUの場合true
    let recommendedMaxWorkingSetGB: Int
}
```

**用途**: デバッグ情報コピー時にWorkspaceConfigurationと一緒に出力

---

## 7. 修飾キーによる強制Block

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

## 設定例：LG右下→内蔵右上ワープ

### シナリオ

- 内蔵ディスプレイ top: 全域からLGへ移動可能
- LG bottom: 左側は内蔵全域へ、右側は内蔵右上へワープ

### PassSegment設定

```swift
// 内蔵ディスプレイ.passSegments
[
    PassSegment(
        id: UUID("..."),
        displayId: UUID("builtin-uuid"),
        side: .top,
        logical: SegmentRange(start: 0.0, end: 3440.0),
        physical: SegmentRange(start: 0.0, end: 342.6),
        pairedSegmentId: UUID("..."),
        pairedDisplayId: UUID("lg-uuid"),
        pairedDisplayName: "LG ULTRAGEAR+",
        pairedSide: .bottom
    ),
    PassSegment(
        id: UUID("..."),
        displayId: UUID("builtin-uuid"),
        side: .top,
        logical: SegmentRange(start: 3456.0, end: 3456.0),  // 空セグメント
        physical: SegmentRange(start: 344.2, end: 344.2),
        pairedSegmentId: UUID("..."),
        pairedDisplayId: UUID("lg-uuid"),
        pairedDisplayName: "LG ULTRAGEAR+",
        pairedSide: .bottom
    )
]

// LGディスプレイ.passSegments
[
    PassSegment(
        id: UUID("..."),
        displayId: UUID("lg-uuid"),
        side: .bottom,
        logical: SegmentRange(start: 0.0, end: 1125.0),
        physical: SegmentRange(start: 0.0, end: 344.2),
        pairedSegmentId: UUID("..."),
        pairedDisplayId: UUID("builtin-uuid"),
        pairedDisplayName: "Built-in Retina Display",
        pairedSide: .top
    ),
    PassSegment(
        id: UUID("..."),
        displayId: UUID("lg-uuid"),
        side: .bottom,
        logical: SegmentRange(start: 1125.0, end: 3440.0),
        physical: SegmentRange(start: 344.2, end: 1052.7),
        pairedSegmentId: UUID("..."),
        pairedDisplayId: UUID("builtin-uuid"),
        pairedDisplayName: "Built-in Retina Display",
        pairedSide: .top
    )
]
```

### 動作確認

**1. 内蔵 x=1000px → LG**
- builtin-top-1に含まれる（0≤1000≤3440）
- 比率: 1000/3440 = 0.29
- LG: 0 + 0.29×1125 = 326px

**2. LG x=2000px → 内蔵（ワープ）**
- lg-bottom-2に含まれる（1125≤2000≤3440）
- ペア: builtin-top-2（空セグメント）
- 内蔵: 3456px（右端へワープ）

---

## まとめ

この設計により：

1. **シンプル**: PassSegmentのみ管理、Blockは暗黙的
2. **高速**: 実座標値で直接比較、正規化不要
3. **柔軟**: 任意のEdge同士をペアリング可能
4. **安定**: メインディスプレイ変更の影響なし
5. **拡張性**: 空セグメントで複雑な動作も表現可能
6. **デバッグ性**: 階層化JSONで比較しやすい
