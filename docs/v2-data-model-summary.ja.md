# LaserGuide v2 データモデル サマリー

## 🎯 今日の成果

久しぶりにプロジェクトを触り、v2として全面的なデータモデル再設計を完了しました。

---

## 📊 完成したデータモデル

### 1. Display（階層化・対称的構造）

```swift
struct Display: Identifiable, Codable {
    let id: UUID
    var hardware: HardwareInfo          // fingerprint含む
    var coordinates: CoordinatesInfo    // logical/physical完全対称
    var display: DisplayInfo            // resolution.ppi含む
    var visual: VisualInfo              // 色・HDR
    var osPassSegments: [PassSegment]   // OS標準
    var passSegments: [PassSegment]     // ユーザー設定
}
```

**JSON例**（実際の内蔵ディスプレイ）:
```json
{
  "id": "...",
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
    "name": "Built-in Retina Display",
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
    "bitsPerSample": 8,
    "colorDepth": 520,
    "hdrMaxValue": 1,
    "hdrMaxPotentialValue": 16
  }
}
```

### 2. PassSegment（実座標値・自動更新）

```swift
struct PassSegment: Identifiable, Codable {
    let id: UUID
    let displayId: UUID
    let side: EdgeSide
    let logical: SegmentRange    // px（実座標値）
    let physical: SegmentRange   // mm（実座標値）
    
    private(set) var pairedSegmentId: UUID
    private(set) var pairedDisplayId: UUID?
    private(set) var pairedDisplayName: String?
    private(set) var pairedSide: EdgeSide?
    
    // キャッシュ（JSON除外）
    private var _display: Display?
    private var _pairedSegment: PassSegment?
    var display: Display? { ... }
    var pairedSegment: PassSegment? { ... }  // 設定時に自動更新
}
```

**JSON例**:
```json
{
  "id": "...",
  "displayId": "builtin-uuid",
  "side": "top",
  "logical": {"start": 0, "end": 3440},
  "physical": {"start": 0, "end": 342.6},
  "pairedSegmentId": "...",
  "pairedDisplayId": "lg-uuid",
  "pairedDisplayName": "LG ULTRAGEAR+",
  "pairedSide": "bottom"
}
```

### 3. AppConfiguration（機能別設定）

```swift
struct AppConfiguration: Codable {
    var workspaceKey: String
    var laser: LaserConfiguration
    var edgeNavigation: EdgeNavigationConfiguration
    var autoLaunchEnabled: Bool
    
    // キャッシュ（JSON除外）
    private var _workspace: WorkspaceConfiguration?
    var workspace: WorkspaceConfiguration? { ... }
}
```

**JSON例**:
```json
{
  "workspaceKey": "config_000006100000A051FD626D62-3456x2234x1_...",
  "laser": {
    "enabled": true,
    "color": "blue",
    "width": 8,
    "opacity": 0.3,
    "inactivityThreshold": 0.3
  },
  "edgeNavigation": {
    "enabled": true,
    "forceBlockEnabled": true,
    "forceBlockModifiers": {"option": true}
  },
  "autoLaunchEnabled": false
}
```

### 4. WorkspaceConfiguration（ディスプレイ構成）

```swift
struct WorkspaceConfiguration: Codable {
    let id: UUID
    let configurationKey: String
    var displays: [Display]
    var metadata: ConfigMetadata
    
    struct ConfigMetadata: Codable {
        let created: Date
        var modified: Date
        let appVersion: String
        let gitCommit: String?
        let gitBranch: String?
        // ...
    }
}
```

---

## 🎨 設計の特徴

### 1. 階層化・対称的
- logical/physical が完全に同じ構造
- 比較が容易

### 2. 自動更新
- `pairedSegment`設定時にヒント自動更新
- `workspace`設定時にキー自動更新

### 3. キャッシュ最適化
- `private`フィールドでJSON除外
- `private(set)`で読み取り専用
- デシリアライズ後に`initialize()`で復元

### 4. デバッグ性
- 16進参照フィールド
- pairedDisplayName
- fingerprint文字列

### 5. 拡張性
- 機能別設定
- SystemMetadata
- Git情報

---

## 🔑 Fingerprint仕様

### 形式
```
000006100000A051FD626D62-3456x2234x1
^^^^^^^^^^^^^^^^^^^^^^^^-^^^^^^^^^^^
24文字固定16進数        幅x高さxスケール
```

### 設定キー
```
config_000006100000A051FD626D62-3456x2234x1_00001E6D00009E8B0007543B-3440x1440x1
```

- URL安全（`+`なし）
- ファイル名安全
- アンダーバーで分割可能
- 固定長で視認性良好

---

## 💾 保存構造

### UserDefaults
```
"LaserGuide.v2.AppConfiguration"
  → AppConfiguration（1つ）
  
"LaserGuide.v2.Workspace.config_xxx"
  → WorkspaceConfiguration（複数、on-demand）
```

### JSON保存内容

**AppConfiguration**:
- workspaceKey のみ
- laser/edgeNavigation設定
- workspace参照は除外

**WorkspaceConfiguration**:
- displays（osPassSegments/passSegments含む）
- metadata（Git情報含む）
- display/_pairedSegment参照は除外

### デバッグ出力

```json
{
  "appConfiguration": {
    "workspaceKey": "...",
    "laser": { ... },
    "workspace": {  ← デバッグ時のみ追加
      "displays": [ ... ]
    }
  },
  "system": {
    "osVersion": "15.6.0",
    "hardwareModel": "MacBookPro18,2",
    "cpuBrand": "Apple M1 Max",
    "memoryGB": 64,
    "gpus": [ ... ]
  }
}
```

---

## ✅ 達成した設計目標

1. **座標系の統一**: SpriteKit、左下原点、Y軸反転不要
2. **データの正規化**: 論理座標は実行時取得、物理座標のみ保存
3. **階層化構造**: logical/physical完全対称
4. **シンプルなエッジ管理**: PassSegmentのみ、Block暗黙的
5. **自動更新**: ペアリング・ヒント自動設定
6. **デバッグ性**: 16進参照、名前ヒント
7. **拡張性**: 機能別設定、Git情報
8. **パフォーマンス**: 実座標値、キャッシュ

---

## 📝 次回以降の作業

### Phase 5: Xcodeプロジェクト更新とビルド
- 新規ファイルをXcodeプロジェクトに追加
- Code Signing設定
- ビルドテスト

### Phase 6: キャリブレーションUI
- SpriteKitでディスプレイ配置エディター
- PassSegmentエディター
- ライブプレビュー

### Phase 7: エッジ越境実装
- PP/PB/BP/BBパターン実装
- CGEventでのマウス座標書き換え
- エッジ交点計算

### Phase 8: 統合テスト
- 複数ディスプレイでの動作確認
- パフォーマンステスト
- バグ修正

---

## 🎓 学んだこと

1. **DisplayFingerprint**: 解像度含む、回転で別設定
2. **16進数固定長**: vendor/model/serial 各8桁
3. **x統一形式**: `3456x2234x1`、`@`不要
4. **private(set)**: 読み取り専用、JSON保存可能
5. **private**: JSON自動除外、キャッシュ用
6. **空セグメント**: `start==end`でワープポイント
7. **実座標値**: 正規化不要、高速
8. **階層化JSON**: カテゴリ別で読みやすい

---

## 🙏 まとめ

LaserGuide v2のデータモデルは、議論を重ねて非常に洗練された設計になりました：

- ✅ シンプル
- ✅ 高速
- ✅ 拡張可能
- ✅ デバッグしやすい
- ✅ プライバシー配慮

設計書も完成し（560行）、実装コードも完成しました。

次回以降、Xcodeプロジェクト更新→ビルド→UI実装と進めていけます。

素晴らしいセッションでした！お疲れ様でした！

